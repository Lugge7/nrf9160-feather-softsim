#
# GNSS sample with nRF Cloud A-GNSS over CoAP, ported to the Feather over SoftSIM.
# src/ and Kconfig are copied from nrf/samples/cellular/gnss so they can be re-synced;
# every board-specific change lives in prj.conf, sysbuild.conf and pm_static.yml.
#
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause
#

cmake_minimum_required(VERSION 3.20.0)

# Same wiring as the other SoftSIM apps here: upstream onomondo hardcodes
# $ENV{ZEPHYR_BASE}/../modules/lib/onomondo-softsim, which assumes west pulled the module
# into the NCS workspace. We keep it out-of-tree under this project instead.
set(SOFTSIM_MODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../modules/onomondo-softsim" CACHE PATH "onomondo-softsim module root")
if(NOT EXISTS "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")
  message(FATAL_ERROR "onomondo-softsim not found at ${SOFTSIM_MODULE_DIR}. Clone it with:\n"
                      "  git clone https://github.com/onomondo/nrf-softsim.git modules/onomondo-softsim\n"
                      "  git -C modules/onomondo-softsim submodule update --init")
endif()
list(APPEND OVERLAY_CONFIG "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")

# Must come last: the module overlay pins CONFIG_PM_PARTITION_SIZE_TFM=0x18000 and this
# gives back the 0x200 that MCUboot's pad takes. See overlay-mcuboot.conf.
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlay-mcuboot.conf")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(gnss_agnss)

zephyr_library_sources(src/main.c)

# Upstream also builds src/assistance_supl.c under CONFIG_GNSS_SAMPLE_ASSISTANCE_SUPL.
# That file is not copied: the SUPL client library is a separate licensed download that is
# not in nrf/ext/lib/bin/supl here, so selecting it could not link anyway. nRF Cloud A-GNSS
# over CoAP replaces it.
zephyr_library_sources_ifdef(CONFIG_GNSS_SAMPLE_ASSISTANCE_NRF_CLOUD src/assistance.c)
zephyr_library_sources_ifdef(CONFIG_GNSS_SAMPLE_ASSISTANCE_MINIMAL src/assistance_minimal.c)
zephyr_library_sources_ifdef(CONFIG_GNSS_SAMPLE_ASSISTANCE_MINIMAL src/mcc_location_table.c)
