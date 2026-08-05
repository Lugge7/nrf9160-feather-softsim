# SPDX-FileCopyrightText: Copyright (c) 2023-2024 Onomondo ApS
# SPDX-License-Identifier: GPL-3.0-only

cmake_minimum_required(VERSION 3.20.0)

# Upstream hardcodes $ENV{ZEPHYR_BASE}/../modules/lib/onomondo-softsim, which assumes
# the module was pulled in by west into the NCS workspace. We keep it out-of-tree under
# this project instead, so point at it directly.
set(SOFTSIM_MODULE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../modules/onomondo-softsim" CACHE PATH "onomondo-softsim module root")
if(NOT EXISTS "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")
  message(FATAL_ERROR "onomondo-softsim not found at ${SOFTSIM_MODULE_DIR}. Clone it with:\n"
                      "  git clone https://github.com/onomondo/nrf-softsim.git modules/onomondo-softsim\n"
                      "  git -C modules/onomondo-softsim submodule update --init")
endif()
list(APPEND OVERLAY_CONFIG "${SOFTSIM_MODULE_DIR}/overlay-softsim.conf")

# Must come after the module overlay: it re-sizes the TF-M partition that
# overlay-softsim.conf pins to 0x18000, to keep the non-secure start address
# 32 KB aligned once MCUboot's pad is in the layout. See the file for the sums.
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlay-mcuboot.conf")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(softsim)

target_sources(app PRIVATE src/main.c src/profile_serial.c)
