/*
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * LTE-M / NB-IoT throughput probe for the nRF9160 Feather.
 *
 * Downloads a fixed byte count over plain HTTP and reports the rate. Loops
 * forever with a pause between runs, so the band can be changed from the AT
 * console (AT+CFUN=0 / AT%XBANDLOCK / AT+CFUN=1) between measurements without
 * reflashing -- the next result line reflects the new band.
 *
 * Plain HTTP on purpose: TLS on a 64 MHz M33 would measure the handshake and
 * record layer as much as the radio.
 */

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>

#include <nrf_softsim.h>
#include <modem/lte_lc.h>
#include <modem/nrf_modem_lib.h>
#include <nrf_modem_at.h>
#include <zephyr/kernel.h>
#include <zephyr/net/socket.h>
#include <zephyr/logging/log.h>

LOG_MODULE_REGISTER(throughput, LOG_LEVEL_INF);

/* Tele2's public speedtest host -- same operator the SIM roams onto, so the
 * path stays short. A Range request bounds the transfer instead of pulling the
 * whole 1 MB file. */
#define DL_HOST  "speedtest.tele2.net"
#define DL_PORT  "80"
#define DL_PATH  "/1MB.zip"

/* Enough to reach steady state on LTE-M (~15-25 s) without burning PAYG data. */
#define DL_BYTES (100 * 1024)

#define RX_CHUNK   1024
#define PAUSE_SECS 20

K_SEM_DEFINE(lte_connected, 0, 1);

static uint8_t rx_buf[RX_CHUNK];

static void lte_handler(const struct lte_lc_evt *const evt)
{
	switch (evt->type) {
	case LTE_LC_EVT_NW_REG_STATUS:
		if ((evt->nw_reg_status == LTE_LC_NW_REG_REGISTERED_HOME) ||
		    (evt->nw_reg_status == LTE_LC_NW_REG_REGISTERED_ROAMING)) {
			k_sem_give(&lte_connected);
		}
		break;
	default:
		break;
	}
}

/* Current serving band and radio conditions, so each result line carries the
 * context it was measured under. */
static void log_radio(const char *tag)
{
	char resp[128];
	int band = -1;
	int rsrp_idx = -1, snr_idx = -1;

	if (nrf_modem_at_scanf("AT%XCBAND", "%%XCBAND: %d", &band) != 1) {
		band = -1;
	}

	/* %CONEVAL: <result>,<rrc>,<energy>,<rsrp>,<rsrq>,<snr>,... */
	if (nrf_modem_at_cmd(resp, sizeof(resp), "AT%%CONEVAL") == 0) {
		int result, rrc, energy, rsrq_idx;

		if (sscanf(resp, "%%CONEVAL: %d,%d,%d,%d,%d,%d", &result, &rrc, &energy,
			   &rsrp_idx, &rsrq_idx, &snr_idx) != 6) {
			rsrp_idx = -1;
		}
	}

	if (rsrp_idx >= 0) {
		LOG_INF("%s band=%d rsrp=%d dBm snr=%d dB", tag, band, rsrp_idx - 140,
			snr_idx - 24);
	} else {
		LOG_INF("%s band=%d (radio metrics unavailable)", tag, band);
	}
}

/* Returns bytes received, or negative on failure. */
static int download_once(uint32_t *elapsed_ms)
{
	struct addrinfo *res = NULL;
	struct addrinfo hints = {
		.ai_family = AF_INET,
		.ai_socktype = SOCK_STREAM,
	};
	char req[192];
	int fd = -1;
	int total = 0;
	int64_t start;
	int err;

	err = getaddrinfo(DL_HOST, DL_PORT, &hints, &res);
	if (err) {
		LOG_ERR("DNS failed for " DL_HOST ": %d", err);
		return -1;
	}

	fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		LOG_ERR("socket() failed: %d", errno);
		freeaddrinfo(res);
		return -1;
	}

	if (connect(fd, res->ai_addr, res->ai_addrlen) < 0) {
		LOG_ERR("connect() failed: %d", errno);
		goto out;
	}

	/* Range caps the transfer server-side, so a slow link cannot overshoot
	 * the byte budget. Connection: close lets the server signal the end. */
	err = snprintf(req, sizeof(req),
		       "GET " DL_PATH " HTTP/1.1\r\n"
		       "Host: " DL_HOST "\r\n"
		       "Range: bytes=0-%d\r\n"
		       "Connection: close\r\n\r\n",
		       DL_BYTES - 1);
	if (err <= 0 || err >= (int)sizeof(req)) {
		LOG_ERR("request too long");
		goto out;
	}

	if (send(fd, req, err, 0) < 0) {
		LOG_ERR("send() failed: %d", errno);
		goto out;
	}

	/* Time from request sent to last byte. Includes the server's response
	 * headers (~200 B), which is noise at this scale. */
	start = k_uptime_get();

	while (total < DL_BYTES) {
		int n = recv(fd, rx_buf, sizeof(rx_buf), 0);

		if (n == 0) {
			break; /* server closed */
		}
		if (n < 0) {
			LOG_ERR("recv() failed after %d bytes: %d", total, errno);
			break;
		}
		total += n;
	}

	*elapsed_ms = (uint32_t)(k_uptime_get() - start);

out:
	if (fd >= 0) {
		(void)close(fd);
	}
	freeaddrinfo(res);
	return total > 0 ? total : -1;
}

int main(void)
{
	int32_t err;

	LOG_INF("Throughput probe starting (%d KB per run)", DL_BYTES / 1024);

#ifndef CONFIG_SOFTSIM_AUTO_INIT
	/* Only when the module's SYS_INIT is compiled out. Calling this while
	 * auto-init is on double-initialises the filesystem and restarts an
	 * already-running work queue, and the SIM never comes up. */
	if (nrf_softsim_init()) {
		LOG_ERR("Failed to initialize SoftSIM.");
		return -1;
	}
#endif

	if (!nrf_softsim_check_provisioned()) {
		LOG_ERR("No SoftSIM profile provisioned. Flash apps/softsim first.");
		return -1;
	}

	err = nrf_modem_lib_init();
	if (err) {
		LOG_ERR("Failed to initialize modem library: %d", err);
		return -1;
	}

#ifndef CONFIG_SOFTSIM_AUTO_INIT
	/* With auto-init the module's NRF_MODEM_LIB_ON_INIT hook already sent this. */
	if (nrf_modem_at_printf("AT%%CSUS=2")) {
		LOG_ERR("Failed to select software SIM.");
	}
#endif

	if (lte_lc_connect_async(lte_handler)) {
		LOG_ERR("lte_lc_connect_async failed");
		return -1;
	}

	LOG_INF("Waiting for LTE...");
	k_sem_take(&lte_connected, K_FOREVER);
	LOG_INF("LTE connected.");

	while (1) {
		uint32_t ms = 0;
		int got;

		/* The band may have been changed over AT since the last run; wait
		 * for the link to come back rather than reporting a failure. */
		if (k_sem_take(&lte_connected, K_NO_WAIT) == 0) {
			LOG_INF("link re-established");
		}

		log_radio("before:");

		got = download_once(&ms);
		if (got < 0 || ms == 0) {
			LOG_ERR("RESULT band=? FAILED");
		} else {
			/* bits/ms == kbit/s, so no 64-bit division needed. */
			uint32_t kbps = ((uint32_t)got * 8U) / ms;

			LOG_INF("RESULT bytes=%d time=%u ms rate=%u kbps (%u.%02u KB/s)", got,
				ms, kbps, (got / 1024U * 1000U) / ms,
				(((got / 1024U * 1000U) * 100U) / ms) % 100U);
		}

		k_sleep(K_SECONDS(PAUSE_SECS));
	}
}
