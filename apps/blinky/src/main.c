/*
 * Blinky: toolchain smoke test, built for both boards in this repo.
 *
 * Drives whatever the board's "led0" alias points at:
 *   Feather  blue LED D7,  gpio0 pin 3,  GPIO_ACTIVE_LOW
 *            zephyr/boards/circuitdojo/feather/circuitdojo_feather_nrf9160_common.dtsi
 *   Icarus   red LED,      gpio0 pin 10, GPIO_ACTIVE_LOW
 *            zephyr/boards/actinius/icarus/actinius_icarus_common.dtsi
 *
 * Note the Feather's D7 is wired active HIGH against its own board DTS, so its
 * LED runs inverted from what this code says; the Icarus's declaration is honest.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/printk.h>

#define SLEEP_TIME_MS 500

#define LED0_NODE DT_ALIAS(led0)

static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(LED0_NODE, gpios);

int main(void)
{
	int ret;
	bool led_on = true;

	printk("%s blinky\n", CONFIG_BOARD_TARGET);

	if (!gpio_is_ready_dt(&led)) {
		printk("error: LED device %s is not ready\n", led.port->name);
		return 0;
	}

	ret = gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);
	if (ret < 0) {
		printk("error: gpio_pin_configure_dt failed (%d)\n", ret);
		return 0;
	}

	while (1) {
		ret = gpio_pin_toggle_dt(&led);
		if (ret < 0) {
			printk("error: gpio_pin_toggle_dt failed (%d)\n", ret);
			return 0;
		}

		led_on = !led_on;
		printk("LED %s\n", led_on ? "ON" : "OFF");
		k_msleep(SLEEP_TIME_MS);
	}

	return 0;
}
