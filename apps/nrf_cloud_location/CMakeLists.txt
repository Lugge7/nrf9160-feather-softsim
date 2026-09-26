# SPDX-FileCopyrightText: Copyright (c) 2025 Nordic Semiconductor ASA
# SPDX-License-Identifier: LicenseRef-Nordic-5-Clause

cmake_minimum_required(VERSION 3.20.0)

# Same wiring as apps/softsim: upstream hardcodes
# $ENV{ZEPHYR_BASE}/../modules/lib/onomondo-softsim, which assumes west pulled the module
# into the NCS workspace. We keep it out-of-tree under this project instead.
set(SOFTSIM_MODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../modules/onomondo-softsim" CACHE PATH "onomondo-softsim module root")
if(NOT EXISTS "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")
  message(FATAL_ERROR "onomondo-softsim not found at ${SOFTSIM_MODULE_DIR}. Clone it with:\n"
                      "  git clone https://github.com/onomondo/nrf-softsim.git modules/onomondo-softsim\n"
                      "  git -C modules/onomondo-softsim submodule update --init")
endif()
list(APPEND OVERLAY_CONFIG "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")

# Must come after the module overlay, which pins CONFIG_PM_PARTITION_SIZE_TFM=0x18000.
# See overlay-mcuboot.conf for the alignment sums.
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlay-mcuboot.conf")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(nrf_cloud_location)

target_sources(app PRIVATE src/main.c)
