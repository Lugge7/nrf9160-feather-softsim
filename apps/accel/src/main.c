/*
 * LIS2DH accelerometer readout for the Circuit Dojo nRF9160 Feather.
 *
 * Reports raw acceleration plus the board's resting orientation, derived from which way
 * gravity points. No modem, so this costs no cellular data.
 *
 * The sensor sits on i2c1 at 0x18 and is already described by the board DTS as
 * `lis2dh: lis2dh@18` -- see
 * zephyr/boards/circuitdojo/feather/circuitdojo_feather_nrf9160_common.dtsi:139.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <math.h>
#include <stdio.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/sensor.h>

#define SAMPLE_PERIOD_MS 500

/* picolibc only exposes M_PI under _DEFAULT_SOURCE, which Zephyr does not set here. */
#define RAD_TO_DEG (180.0 / 3.14159265358979323846)

/* Gravity is ~9.81 m/s^2. A face counts as "down" only when it carries most of that, so a
 * board held at an angle reports "tilted" rather than flickering between two faces.
 */
#define FACE_THRESHOLD 7.0

static const struct device *const accel = DEVICE_DT_GET_ANY(st_lis2dh);

static const char *orientation(double x, double y, double z)
{
	if (z >= FACE_THRESHOLD) {
		return "flat, component side up";
	}
	if (z <= -FACE_THRESHOLD) {
		return "flat, component side down";
	}
	if (x >= FACE_THRESHOLD) {
		return "on its side (+X down)";
	}
	if (x <= -FACE_THRESHOLD) {
		return "on its side (-X down)";
	}
	if (y >= FACE_THRESHOLD) {
		return "upright (+Y down)";
	}
	if (y <= -FACE_THRESHOLD) {
		return "upright (-Y down)";
	}

	return "tilted";
}

int main(void)
{
	struct sensor_value val[3];
	int err;

	printk("nRF9160 Feather accelerometer (LIS2DH)\n");

	if (accel == NULL) {
		printk("error: no st,lis2dh node found in the devicetree\n");
		return 0;
	}

	if (!device_is_ready(accel)) {
		printk("error: %s is not ready -- check the i2c1 bus and that the sensor is "
		       "powered\n",
		       accel->name);
		return 0;
	}

	printk("Reading %s every %d ms\n\n", accel->name, SAMPLE_PERIOD_MS);

	while (1) {
		err = sensor_sample_fetch(accel);
		if (err) {
			printk("error: sensor_sample_fetch failed (%d)\n", err);
			k_msleep(SAMPLE_PERIOD_MS);
			continue;
		}

		err = sensor_channel_get(accel, SENSOR_CHAN_ACCEL_XYZ, val);
		if (err) {
			printk("error: sensor_channel_get failed (%d)\n", err);
			k_msleep(SAMPLE_PERIOD_MS);
			continue;
		}

		double x = sensor_value_to_double(&val[0]);
		double y = sensor_value_to_double(&val[1]);
		double z = sensor_value_to_double(&val[2]);

		/* Tilt away from flat. Roll is rotation about X, pitch about Y; both are
		 * undefined in yaw because gravity alone cannot observe heading.
		 */
		double roll = atan2(y, z) * RAD_TO_DEG;
		double pitch = atan2(-x, sqrt(y * y + z * z)) * RAD_TO_DEG;
		double magnitude = sqrt(x * x + y * y + z * z);

		printf("X %7.2f  Y %7.2f  Z %7.2f m/s^2 | |a| %5.2f | roll %7.2f  pitch %7.2f deg | %s\n",
		       x, y, z, magnitude, roll, pitch, orientation(x, y, z));

		k_msleep(SAMPLE_PERIOD_MS);
	}

	return 0;
}
