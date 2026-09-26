# SPDX-License-Identifier: Apache-2.0
#
# Memfault's cellular demo app, ported to the Feather over SoftSIM. Source and config/
# are taken unmodified from
#   modules/lib/memfault-firmware-sdk/examples/nrf-connect-sdk/cellular/memfault_demo_app
# so they can be re-synced from upstream; every Feather-specific change lives in this
# file, prj.conf, sysbuild.conf and pm_static.yml.

cmake_minimum_required(VERSION 3.20.0)

# Upstream selects Kconfig fragments by NCS version, because setting a symbol that does not
# exist in a given SDK is a build error. Only the >= 3.3.0 branches can apply here (this
# tree is 3.4.0), so just those two overlays were copied.
#
# Upstream detects the version with `find_package(Ncs)` before `find_package(Zephyr)`. That
# does not work under sysbuild: NcsConfig.cmake reads the CMake variable ZEPHYR_BASE (not
# the environment one) and does `include(${ZEPHYR_BASE}/cmake/modules/version.cmake)`, so
# before Zephyr is found it tries to include `/cmake/modules/version.cmake` and the build
# dies with a misleading "NCS Version not found, please contact Memfault support!".
# Reading nrf/VERSION directly avoids the ordering problem entirely.
file(READ "$ENV{ZEPHYR_BASE}/../nrf/VERSION" ncs_version_file)
string(REGEX MATCH "VERSION_MAJOR = ([0-9]+)" _ "${ncs_version_file}")
set(ncs_major ${CMAKE_MATCH_1})
string(REGEX MATCH "VERSION_MINOR = ([0-9]+)" _ "${ncs_version_file}")
set(ncs_minor ${CMAKE_MATCH_1})
string(REGEX MATCH "PATCHLEVEL = ([0-9]+)" _ "${ncs_version_file}")
set(ncs_patch ${CMAKE_MATCH_1})
if("${ncs_major}.${ncs_minor}.${ncs_patch}" VERSION_LESS 3.3.0)
  message(FATAL_ERROR "This port only carries the NCS >= 3.3.0 overlays; found "
                      "${ncs_major}.${ncs_minor}.${ncs_patch}. "
                      "Re-copy overlays/ from the upstream example.")
endif()
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlays/ncs-main.conf")
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlays/ncs-v3.3.0.conf")

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

# The Memfault project key is an ingestion credential, so it is not committed. profiles/ is
# gitignored; drop a one-line fragment there:
#
#   CONFIG_MEMFAULT_NCS_PROJECT_KEY="<key from Memfault -> Settings -> General>"
#
# Without it the build still succeeds and the device runs, but every chunk upload is
# rejected, so fail loudly here instead of debugging 401s on the wire.
set(MEMFAULT_KEY_CONF "${CMAKE_CURRENT_SOURCE_DIR}/../../profiles/memfault_key.conf")
if(NOT EXISTS "${MEMFAULT_KEY_CONF}")
  message(FATAL_ERROR "Missing ${MEMFAULT_KEY_CONF}. Create it with one line:\n"
                      "  CONFIG_MEMFAULT_NCS_PROJECT_KEY=\"<your project key>\"")
endif()
list(APPEND OVERLAY_CONFIG "${MEMFAULT_KEY_CONF}")

# Must come last: the module overlay pins CONFIG_PM_PARTITION_SIZE_TFM=0x18000 and this
# gives back the 0x200 that MCUboot's pad takes. See overlay-mcuboot.conf.
list(APPEND OVERLAY_CONFIG "${CMAKE_CURRENT_SOURCE_DIR}/overlay-mcuboot.conf")

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(memfault_feather)

target_sources(app PRIVATE src/main.c)
target_sources(app PRIVATE src/watchdog.c)
zephyr_include_directories(config)
