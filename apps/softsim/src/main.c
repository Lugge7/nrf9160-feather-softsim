/*
 * SPDX-FileCopyrightText: Copyright (c) 2023-2026 Onomondo ApS
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netdb.h>

#include <nrf_softsim.h>
#include <modem/lte_lc.h>
#include <modem/nrf_modem_lib.h>
#include <nrf_modem_at.h>
#include <zephyr/kernel.h>
#include <zephyr/net/socket.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/logging/log.h>
#include <zephyr/logging/log_ctrl.h>
#include <zephyr/sys/reboot.h>

#include "profile_serial.h"
#include "status_led.h"

LOG_MODULE_REGISTER(softsim_sample, LOG_LEVEL_INF);

/* Headroom over the full SoftSIM profile (~410 chars incl. SMSP/PIN/SMSC) */
#define PROFILE_MAX_SIZE 512

K_SEM_DEFINE(lte_connected, 0, 1); /* Semaphore to signal LTE connection established */

static const struct device *const uart_dev = DEVICE_DT_GET(DT_NODELABEL(uart0));

static void lte_handler(const struct lte_lc_evt *const evt)
{
	switch (evt->type) {
	case LTE_LC_EVT_NW_REG_STATUS:
		if ((evt->nw_reg_status != LTE_LC_NW_REG_REGISTERED_HOME) &&
		    (evt->nw_reg_status != LTE_LC_NW_REG_REGISTERED_ROAMING)) {
			/* Not registered. Distinguish "still looking" from "the network
			 * said no", since the second one will not fix itself.
			 */
			switch (evt->nw_reg_status) {
			case LTE_LC_NW_REG_REGISTRATION_DENIED:
			case LTE_LC_NW_REG_UICC_FAIL:
				status_led_set(STATUS_LED_ERROR);
				break;
			default:
				status_led_set(STATUS_LED_LTE_SEARCHING);
				break;
			}
			break;
		}

		LOG_INF("Network registration status: %s",
			evt->nw_reg_status == LTE_LC_NW_REG_REGISTERED_HOME
				? "Connected - home network"
				: "Connected - roaming");
		status_led_set(STATUS_LED_LTE_CONNECTED);
		k_sem_give(&lte_connected);
		break;
	case LTE_LC_EVT_PSM_UPDATE:
		LOG_INF("PSM parameter update: TAU: %d, Active time: %d", evt->psm_cfg.tau,
			evt->psm_cfg.active_time);
		break;
	case LTE_LC_EVT_EDRX_UPDATE: {
		char log_buf[60];
		ssize_t len;

		len = snprintf(log_buf, sizeof(log_buf), "eDRX parameter update: eDRX: %f, PTW: %f",
			       (double)evt->edrx_cfg.edrx, (double)evt->edrx_cfg.ptw);
		if (len > 0) {
			LOG_INF("%s", log_buf);
		}
		break;
	}
	case LTE_LC_EVT_RRC_UPDATE:
		LOG_INF("RRC mode: %s",
			evt->rrc_mode == LTE_LC_RRC_MODE_CONNECTED ? "Connected" : "Idle");
		break;
	case LTE_LC_EVT_CELL_UPDATE:
		LOG_INF("LTE cell changed: Cell ID: %d, Tracking area: %d", evt->cell.id,
			evt->cell.tac);
		break;
	default:
		break;
	}
}

static void modem_connect(void)
{
	int err = lte_lc_connect_async(lte_handler);
	if (err) {
		LOG_ERR("Connecting to LTE network failed, error: %d", err);
		status_led_set(STATUS_LED_ERROR);
		return;
	}
	status_led_set(STATUS_LED_LTE_SEARCHING);
}

/* Reachability check against Google over the SoftSIM data path.
 *
 * The nRF9160's sockets are offloaded to the modem, which exposes no raw ICMP
 * socket, so there is no literal ping. A DNS resolve plus a TCP round-trip is
 * the equivalent proof: it exercises PDN activation, the modem's DNS, and an
 * end-to-end TCP session to Google. One pass moves well under 1 KB, which
 * matters on a PAYG SIM.
 */
static int ping_google(void)
{
	static const char req[] = "HEAD / HTTP/1.1\r\n"
				  "Host: google.com\r\n"
				  "Connection: close\r\n\r\n";
	struct addrinfo *res = NULL;
	struct addrinfo hints = {
		.ai_family = AF_INET,
		.ai_socktype = SOCK_STREAM,
	};
	char addr_str[INET_ADDRSTRLEN];
	char reply[128];
	int64_t t0;
	int fd = -1;
	int err;

	t0 = k_uptime_get();
	err = getaddrinfo("google.com", "80", &hints, &res);
	if (err || res == NULL) {
		LOG_ERR("DNS resolve of google.com failed: %d", err);
		return -1;
	}

	inet_ntop(AF_INET, &((struct sockaddr_in *)res->ai_addr)->sin_addr, addr_str,
		  sizeof(addr_str));
	LOG_INF("DNS: google.com -> %s (%lld ms)", addr_str, k_uptime_get() - t0);

	fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		LOG_ERR("Failed to create TCP socket: %d", errno);
		err = -1;
		goto out;
	}

	t0 = k_uptime_get();
	if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
		LOG_ERR("TCP connect to %s:80 failed: %d", addr_str, errno);
		err = -1;
		goto out;
	}
	LOG_INF("TCP connect to %s:80 OK (%lld ms)", addr_str, k_uptime_get() - t0);

	t0 = k_uptime_get();
	if (send(fd, req, sizeof(req) - 1, 0) < 0) {
		LOG_ERR("Failed to send HTTP request: %d", errno);
		err = -1;
		goto out;
	}

	ssize_t len = recv(fd, reply, sizeof(reply) - 1, 0);
	if (len <= 0) {
		LOG_ERR("No HTTP reply: %d", errno);
		err = -1;
		goto out;
	}

	reply[len] = '\0';
	char *eol = strpbrk(reply, "\r\n");
	if (eol) {
		*eol = '\0';
	}
	LOG_INF("HTTP reply: \"%s\" (round trip %lld ms)", reply, k_uptime_get() - t0);
	err = 0;

out:
	if (fd >= 0) {
		(void)close(fd);
	}
	freeaddrinfo(res);
	return err;
}

static void drain_logs_and_reboot(void)
{
	/* Flush the deferred log buffer over UART before the reboot discards it. */
	while (log_data_pending()) {
		log_process();
		k_yield();
	}
	sys_reboot(0);
}

static int provision_softsim_from_serial(void)
{
	if (!device_is_ready(uart_dev)) {
		LOG_ERR("UART device not found!");
		return -1;
	}

	char *profile = k_malloc(PROFILE_MAX_SIZE);
	__ASSERT_NO_MSG(profile != NULL);

	struct rx_buf_t rx = {
		.buf = profile,
		.len = PROFILE_MAX_SIZE,
		.pos = 0,
	};

	uart_irq_callback_user_data_set(uart_dev, serial_cb, &rx);
	uart_irq_rx_enable(uart_dev);

	status_led_set(STATUS_LED_AWAIT_PROFILE);

	do {
		LOG_INF("Transfer SoftSIM profile using serial COM port, terminate by "
			"newline character (return key)");
	} while (k_sem_take(&profile_received, K_SECONDS(20)));

	LOG_INF("Profile received: %zu characters in total", rx.pos);

	uart_irq_rx_disable(uart_dev);

	/* Provision the profile to the SoftSIM filesystem */
	if (nrf_softsim_provision((uint8_t *)profile, rx.pos) != 0) {
		LOG_ERR("SoftSIM Profile provisioning failed");
		status_led_set(STATUS_LED_ERROR);
	}

	k_free(profile);

#ifndef CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION
	/* Reboot to free the UART for the AT host/monitor and bring the modem up
	 * cleanly with the new SIM. With factory reset enabled we must NOT reboot
	 * here: the modem is still uninitialised (AT commands return -NRF_EPERM, i.e.
	 * -1), so the reset waits until main() has called nrf_modem_lib_init() — see
	 * nrf_softsim_just_provisioned(). */
	drain_logs_and_reboot();
#endif /* !CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION */

	return 0;
}

int main(void)
{
	LOG_INF("SoftSIM sample started.");

#ifndef CONFIG_SOFTSIM_AUTO_INIT
	/* Without auto-init the module's SYS_INIT is compiled out, so bring SoftSIM
	 * up here -- before nrf_softsim_check_provisioned(), which needs the
	 * filesystem this initializes. */
	if (nrf_softsim_init()) {
		LOG_ERR("Failed to initialize SoftSIM.");
		status_led_set(STATUS_LED_ERROR);
		return -1;
	}
#endif

	if (!nrf_softsim_check_provisioned()) {
		if (provision_softsim_from_serial() != 0) {
			return -1;
		}
	}

	status_led_set(STATUS_LED_MODEM_INIT);

	int32_t err = nrf_modem_lib_init();
	if (err) {
		LOG_ERR("Failed to initialize modem library, error: %d", err);
		status_led_set(STATUS_LED_ERROR);
	}

#ifndef CONFIG_SOFTSIM_AUTO_INIT
	/* The module's NRF_MODEM_LIB_ON_INIT hook is compiled out too, so select the
	 * software SIM here. Runtime SIM selection lives at this point: send this
	 * only when a profile is provisioned, and the device falls back to a
	 * physical SIM otherwise. */
	if (nrf_modem_at_printf("AT%%CSUS=2")) {
		LOG_ERR("Failed to select software SIM.");
	}
#endif

#ifdef CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION
	/* Modem is now initialised; if a profile was just provisioned (static or
	 * serial), wipe modem NVM and reboot so it comes up clean with the new SIM. */
	if (!err && nrf_softsim_just_provisioned()) {
		nrf_softsim_modem_factory_reset();
		drain_logs_and_reboot();
	}
#endif /* CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION */

	modem_connect();

	LOG_INF("Waiting for LTE connect event.");
	do {
	} while (k_sem_take(&lte_connected, K_SECONDS(10)));

	LOG_INF("LTE connected!");

	int failures = 0;

	for (int i = 1; i <= 3; i++) {
		LOG_INF("--- Google reachability check %d/3 ---", i);
		status_led_set(STATUS_LED_NET_CHECK);
		if (ping_google() == 0) {
			LOG_INF("--- check %d/3 PASSED ---", i);
		} else {
			LOG_ERR("--- check %d/3 FAILED ---", i);
			failures++;
		}
		status_led_set(STATUS_LED_LTE_CONNECTED);
		k_sleep(K_SECONDS(3));
	}

	LOG_INF("Reachability checks done. Idling.");
	status_led_set(failures ? STATUS_LED_ERROR : STATUS_LED_IDLE_OK);
	return 0;
}
