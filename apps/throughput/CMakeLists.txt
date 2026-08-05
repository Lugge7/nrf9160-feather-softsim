# SPDX-License-Identifier: GPL-3.0-only
#
# Throughput probe. Shares the SoftSIM partition layout with apps/softsim -- the
# SIM filesystem at nvs_storage is already provisioned on the device, so this app
# reuses it rather than re-provisioning.

cmake_minimum_required(VERSION 3.20.0)

set(SOFTSIM_MODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../modules/onomondo-softsim" CACHE PATH "onomondo-softsim module root")
if(NOT EXISTS "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")
  message(FATAL_ERROR "onomondo-softsim not found at ${SOFTSIM_MODULE_DIR}")
endif()
list(APPEND OVERLAY_CONFIG "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")

# Must come after the module overlay -- see overlay-mcuboot.conf for the sums.
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlay-mcuboot.conf")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(throughput)

target_sources(app PRIVATE src/main.c src/profile_serial.c)
