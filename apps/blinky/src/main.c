/*
 * Blinky for the Circuit Dojo nRF9160 Feather.
 *
 * Drives the blue LED (D7) via the board's "led0" alias, which maps to
 * gpio0 pin 3, GPIO_ACTIVE_LOW. See
 * zephyr/boards/circuitdojo/feather/circuitdojo_feather_nrf9160_common.dtsi
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

	printk("nRF9160 Feather blinky\n");

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
