/*
 * Status indication on the board LED(s).
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef STATUS_LED_H_
#define STATUS_LED_H_

/* Ordered roughly by the sequence a healthy boot passes through, so a glance at
 * the colour tells you how far the device got.
 */
enum status_led_state {
	STATUS_LED_BOOT = 0,	   /* blue, solid      -- powered, app running */
	STATUS_LED_AWAIT_PROFILE,  /* blue, fast blink -- waiting for you to paste a profile */
	STATUS_LED_MODEM_INIT,	   /* yellow, solid    -- bringing the modem up */
	STATUS_LED_LTE_SEARCHING,  /* yellow, blink    -- searching for a network */
	STATUS_LED_LTE_CONNECTED,  /* green, solid     -- registered */
	STATUS_LED_NET_CHECK,	   /* cyan, fast blink -- data transfer in progress */
	STATUS_LED_IDLE_OK,	   /* green, heartbeat -- done, all checks passed */
	STATUS_LED_ERROR,	   /* red, fast blink  -- something failed */
};

/* Safe to call from any context, including the LTE event callback: it only
 * stores the new state, and the rendering thread picks it up.
 */
void status_led_set(enum status_led_state state);

#endif /* STATUS_LED_H_ */
