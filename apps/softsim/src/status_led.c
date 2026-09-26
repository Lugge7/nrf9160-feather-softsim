/*
 * Status indication on the board LED(s).
 *
 * Two boards, two capabilities, one API:
 *
 *   Icarus v2  led0/led1/led2 = red/green/blue (gpio0 10/11/12), so state is
 *              carried by colour *and* cadence.
 *   Feather    led0 only (blue D7), so state is carried by cadence alone -- any
 *              non-black colour just lights the single LED.
 *
 * Rendering runs on its own lowest-priority thread. That keeps k_sleep() out of
 * main() and out of the LTE event callback, which must not block: lte_handler()
 * is called from the modem library's own thread.
 *
 * Note on the Feather: its D7 is wired active HIGH while its board DTS declares
 * GPIO_ACTIVE_LOW, so its indication runs inverted -- "on" is dark. That is a
 * board-level quirk, deliberately not compensated for here, because the DTS is
 * what every other app on that board also believes.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "status_led.h"

#include <zephyr/kernel.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/sys/atomic.h>

#define HAS_LED0 DT_NODE_EXISTS(DT_ALIAS(led0))
#define HAS_RGB	 (DT_NODE_EXISTS(DT_ALIAS(led1)) && DT_NODE_EXISTS(DT_ALIAS(led2)))

#if HAS_LED0

#define COLOR_R BIT(0)
#define COLOR_G BIT(1)
#define COLOR_B BIT(2)

#define COLOR_OFF    0
#define COLOR_RED    COLOR_R
#define COLOR_GREEN  COLOR_G
#define COLOR_BLUE   COLOR_B
#define COLOR_YELLOW (COLOR_R | COLOR_G)
#define COLOR_CYAN   (COLOR_G | COLOR_B)

struct led_pattern {
	uint8_t color;
	uint16_t on_ms;	 /* time lit */
	uint16_t off_ms; /* 0 = solid, never darkened */
};

/* Indexed by enum status_led_state. */
static const struct led_pattern patterns[] = {
	[STATUS_LED_BOOT] = {COLOR_BLUE, 1000, 0},
	[STATUS_LED_AWAIT_PROFILE] = {COLOR_BLUE, 150, 150},
	[STATUS_LED_MODEM_INIT] = {COLOR_YELLOW, 1000, 0},
	[STATUS_LED_LTE_SEARCHING] = {COLOR_YELLOW, 300, 300},
	[STATUS_LED_LTE_CONNECTED] = {COLOR_GREEN, 1000, 0},
	[STATUS_LED_NET_CHECK] = {COLOR_CYAN, 100, 100},
	[STATUS_LED_IDLE_OK] = {COLOR_GREEN, 80, 2400},
	[STATUS_LED_ERROR] = {COLOR_RED, 120, 120},
};

static const struct gpio_dt_spec led_r = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);
#if HAS_RGB
static const struct gpio_dt_spec led_g = GPIO_DT_SPEC_GET(DT_ALIAS(led1), gpios);
static const struct gpio_dt_spec led_b = GPIO_DT_SPEC_GET(DT_ALIAS(led2), gpios);
#endif

static atomic_t requested_state = ATOMIC_INIT(STATUS_LED_BOOT);

static void render(uint8_t color)
{
#if HAS_RGB
	(void)gpio_pin_set_dt(&led_r, (color & COLOR_R) ? 1 : 0);
	(void)gpio_pin_set_dt(&led_g, (color & COLOR_G) ? 1 : 0);
	(void)gpio_pin_set_dt(&led_b, (color & COLOR_B) ? 1 : 0);
#else
	/* Single LED: colour collapses to on/off, cadence carries the meaning. */
	(void)gpio_pin_set_dt(&led_r, color ? 1 : 0);
#endif
}

static void status_led_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a);
	ARG_UNUSED(b);
	ARG_UNUSED(c);

	if (!gpio_is_ready_dt(&led_r)) {
		return;
	}
	(void)gpio_pin_configure_dt(&led_r, GPIO_OUTPUT_INACTIVE);
#if HAS_RGB
	(void)gpio_pin_configure_dt(&led_g, GPIO_OUTPUT_INACTIVE);
	(void)gpio_pin_configure_dt(&led_b, GPIO_OUTPUT_INACTIVE);
#endif

	while (1) {
		const struct led_pattern *p = &patterns[atomic_get(&requested_state)];

		render(p->color);
		k_sleep(K_MSEC(p->on_ms));

		/* Re-read rather than sleeping out the dark half blindly, so a state
		 * change during a long gap (IDLE_OK rests for 2.4 s) shows up promptly.
		 */
		if (p->off_ms) {
			render(COLOR_OFF);
			k_sleep(K_MSEC(p->off_ms));
		}
	}
}

K_THREAD_DEFINE(status_led_tid, 768, status_led_thread, NULL, NULL, NULL,
		K_LOWEST_APPLICATION_THREAD_PRIO, 0, 0);

void status_led_set(enum status_led_state state)
{
	atomic_set(&requested_state, (atomic_val_t)state);
}

#else /* !HAS_LED0 -- board with no LED at all */

void status_led_set(enum status_led_state state)
{
	ARG_UNUSED(state);
}

#endif /* HAS_LED0 */
