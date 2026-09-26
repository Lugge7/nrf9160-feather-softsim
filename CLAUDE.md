# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Firmware for two nRF9160 boards, targeting a cellular asset tracker: a **Circuit Dojo nRF9160
Feather** and an **Actinius Icarus v2** (added 2026-09-16). Cellular is up: a Monogoto SoftSIM
(no physical SIM) provisions and registers. `README.md` carries the hardware bring-up narrative
and measured results; this file covers commands and structure.

The two boards share every app; only the board target, the console port, and the flashing route
differ. See [Boards](#boards) before running anything — the wrong board target is the single
easiest way to waste an hour here.

There is no test suite, linter, or CI — the only automated check is
`.\New-SoftSimProfile.ps1 -SelfTest`, which verifies the EF.IMSI/EF.ICCID encoders against the
upstream reference profile.

## Environment

Everything runs from PowerShell with the NCS toolchain dot-sourced first:

```powershell
. .\env.ps1     # PATH, ZEPHYR_BASE, NRFUTIL_HOME for C:\ncs\v3.4.0 + C:\ncs\toolchains\dcbdc366a1
```

nRF Connect SDK **v3.4.0 LTS** (Zephyr 4.4.0). The `/ns` split means every build also compiles
TF-M, so a first build takes 10+ minutes and incrementals ~30 s.

## Boards

| | Feather | Icarus v2 |
|---|---|---|
| Board target | `circuitdojo_feather/nrf9160/ns` | `actinius_icarus@2.0.0/nrf9160/ns` |
| Console | **COM15 @ 115200** (CP2102N) | **COM8 @ 115200** (FTDI FT231X) |
| `led0` | blue D7, gpio0 3 | red, gpio0 10 |
| Debug probe | none onboard — serial DFU | none onboard — external J-Link on SWD |

**The Icarus board target puts the revision before the qualifiers**: `actinius_icarus@2.0.0/nrf9160/ns`.
The Feather-style `actinius_icarus/nrf9160/ns@2.0.0` fails at CMake with "Invalid revision /
qualifiers format for BOARD". Revision `2.0.0` is the board default, but pass it explicitly —
`1.4.0` boards differ in uart0 pins, and rev 2 adds the W25Q64 SPI flash and the charger-enable pin.

`actinius_icarus` also builds a board-control `SYS_INIT` that drives **P0.08** to pick the SIM:
DTS `sim = "esim"` (the default) selects the onboard eSIM, `"external"` the nano-SIM slot. It is
irrelevant to SoftSIM, which bypasses both, but it is why the factory firmware logs
`eSIM is selected`.

**Modem firmware ≥ 1.3.4 is a hard prerequisite for SoftSIM**, because `AT%CSUS` — the command
that selects the software SIM — is documented `v1.3.x≥4`. The Icarus shipped with **1.2.3**, on
which SoftSIM cannot work and fails as an unknown AT command rather than as anything
SoftSIM-shaped. NCS 3.4.0 LTS is only verified against **1.3.7**. Check with `AT+CGMR`, and update
over SWD (app flash, IMEI and eSIM are untouched; Nordic warn that going back to 1.2.x risks
certificate corruption):

```powershell
nrfutil device program --firmware .\firmware\mfw_nrf9160_1.3.7.zip
```

## Build

Each app has its own build directory; `-d` is always passed explicitly.

```powershell
west build -b circuitdojo_feather/nrf9160/ns -d build          apps\blinky
west build -b circuitdojo_feather/nrf9160/ns -d build-at       apps\at_client
west build -b circuitdojo_feather/nrf9160/ns -d build-softsim  apps\softsim `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
west build -b circuitdojo_feather/nrf9160/ns -d build-coap-loc apps\nrf_cloud_coap_location `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
west build -b circuitdojo_feather/nrf9160/ns -d build-memfault apps\memfault `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
west build -b circuitdojo_feather/nrf9160/ns -d build-throughput apps\throughput `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
```

`-DEXTRA_ZEPHYR_MODULES` is **mandatory for any SoftSIM app**. `modules/onomondo-softsim` is
out-of-tree and in no west manifest, so nothing else registers it; without the flag the build
dies on the undefined `SOFTSIM_BUNDLE_TEMPLATE_HEX`. Quote the whole argument or PowerShell
splits it at the drive-letter colon. The flag persists only in that build dir's CMakeCache, so
it is invisible until someone creates a fresh build dir.

For the Icarus, swap the board target and use a separate build dir so the two boards' artifacts
never mix:

```powershell
west build -b actinius_icarus@2.0.0/nrf9160/ns -d build-icarus         apps\blinky
west build -b actinius_icarus@2.0.0/nrf9160/ns -d build-softsim-icarus apps\softsim `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
```

`--pristine` is needed only after changing `sysbuild.conf`, the board target, or Kconfig
defaults. Normal source edits rebuild incrementally. Note `west build -p` takes a *value*
(`-p always`); `--pristine apps\blinky` is parsed as the pristine mode and dies with
"invalid choice".

A build dir remembers its board target, so pointing an existing one at the other board fails
with "targets board X, but board Y was specified" — use the right `-d`, not `--force`.

## Flash

Two paths, and picking the wrong one destroys the SIM provisioning.

**Serial DFU (normal app updates)** — writes the MCUboot app slot only. Board must be in
bootloader mode: hold MODE, tap RST, keep holding MODE until the blue LED is solid.

```powershell
.\flash.ps1 -Image .\build-softsim\softsim\zephyr\zephyr.signed.bin
```

`flash.ps1` defaults to blinky's image; pass `-Image` for anything else (`-Port` to override
COM15).

On the **Icarus** the same path works but three things differ:

```powershell
.\flash.ps1 -Port COM8 -Baud 115200 -Image .\build-icarus\blinky\zephyr\zephyr.signed.bin
```

- **`-Baud 115200` is mandatory.** `flash.ps1` defaults to 1000000 for the Feather; the Icarus's
  `uart0` is `current-speed = <0x1c200>` = 115200, and the default just times out.
- **Bootloader entry is a different gesture**: hold RESET, press the user button, release RESET,
  then release the user button.
- **Nothing lights up.** Our MCUboot build for the Icarus takes MCUboot's raw defaults —
  `BOOT_SERIAL_DETECT_DELAY=0` and no `MCUBOOT_INDICATION_LED` — so bootloader mode is invisible
  and the button must already be held when reset is released. The only confirmation is newtmgr
  connecting. Neither board's Zephyr files set these symbols; adding
  `CONFIG_MCUBOOT_INDICATION_LED=y` would light the blue LED (`mcuboot-led0` alias exists).

Since the Icarus is driven by an external J-Link anyway, SWD is usually the faster loop and skips
the button gesture entirely.

**SWD (J-Link)** — the only way to write outside the app slot.

`nrfutil device program` defaults to **`chip_erase_mode=ERASE_ALL`**, which erases the entire
1 MB of flash plus UICR regardless of what the hex actually spans. Picking the right hex is
therefore not enough: an app-slot hex flashed with the default still wipes the SoftSIM
provisioning at `0xF0000`. Always pass the erase mode explicitly.

```powershell
# One-time bring-up of an unprovisioned device: full image, full erase.
nrfutil device program --firmware .\build-softsim\merged.hex --options chip_erase_mode=ERASE_ALL
nrfutil device reset

# App update on a provisioned device: erase only what the hex covers.
nrfutil device program --firmware .\build-softsim\softsim\zephyr\zephyr.signed.hex `
  --options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE
nrfutil device reset
```

Which hex to use on a provisioned device:

| Artifact | Spans | Effect (with `ERASE_RANGES_TOUCHED_BY_FIRMWARE`) |
|---|---|---|
| `build-softsim\merged.hex` | `0x0`–`0xF1FF8` | MCUboot + TF-M + app + **blank** SIM template — wipes provisioning |
| `build-softsim\softsim\zephyr\zephyr.signed.hex` | `0x10000`–`0x4E048` | app slot only — SIM survives |

`merged.hex` is for the one-time bring-up of an unprovisioned device (see README). After that,
use `zephyr.signed.hex` over SWD or `zephyr.signed.bin` over serial. Verify the address range of
any hex before flashing a provisioned board.

A wiped device is silent in a way that looks like dead hardware: with MCUboot gone from `0x0`
there is no console output at all. `nrfutil device read --address 0x0 --bytes 16` reading back
all `FF` confirms it, and `nrfutil device cpu-register-read --register PC` tells you where the
CPU actually is — an address inside `0x0`–`0x10000` is MCUboot, and `0xEFFFFFFE` is ARM lockup.

If `nrfutil device list` is empty the J-Link has dropped off USB — re-seat it rather than
assuming the board failed.

## Architecture

### Kconfig layering (the thing that trips people up)

For SoftSIM apps, config is assembled from three files in a fixed order, and later ones win:

1. `apps/<app>/prj.conf`
2. `modules/onomondo-softsim/overlay-softsim.conf` — appended to `OVERLAY_CONFIG` by the app's
   `CMakeLists.txt`. Pins `CONFIG_PM_PARTITION_SIZE_TFM=0x18000`, NVS size, TF-M and PSA settings.
3. `apps/<app>/overlay-mcuboot.conf` — appended last, re-sizes TF-M to `0x17E00`.

So anything set in `prj.conf` that the module overlay also sets is **silently overridden**. The
TF-M size lives in `overlay-mcuboot.conf` for exactly this reason: MCUboot inserts a `0x200` pad,
TF-M gives back the same `0x200`, and the non-secure image stays 32 KB aligned — which the
nRF9160 SPU requires. Getting it wrong fails loudly at compile time in TF-M's `assert.c`.

Sysbuild-level symbols (`SB_CONFIG_*`) live in `apps/<app>/sysbuild.conf` and are a separate
namespace from `CONFIG_*`. MCUboot is selected by `SB_CONFIG_BOOTLOADER_MCUBOOT=y` there — the
NCS 2.x `CONFIG_BOOTLOADER_MCUBOOT` form is silently ignored under sysbuild and yields an
unsigned image the bootloader rejects.

### How the SIM filesystem gets onto flash

The SoftSIM needs an 8184-byte directory skeleton (`modules/onomondo-softsim/lib/profile/template.bin`)
living in the `nvs_storage` partition at `0xF0000`. `modules/onomondo-softsim/sysbuild/CMakeLists.txt`
is a sysbuild hook that objcopy's that binary to a hex at the Partition Manager's computed
`nvs_storage` address and, when `SB_CONFIG_SOFTSIM_BUNDLE_TEMPLATE_HEX=y`, folds it into
`merged.hex`. All of it is gated on `SB_CONFIG_PARTITION_MANAGER=y`, which NCS 3.4 no longer
enables by default — hence the explicit opt-in in `sysbuild.conf`.

`apps/throughput/sysbuild.conf` deliberately leaves `SB_CONFIG_SOFTSIM_BUNDLE_TEMPLATE_HEX`
commented out, so its `merged.hex` can never carry a blank template onto a live device.

Consequence: a fresh SoftSIM cannot be brought up over serial DFU. The symptom is
`Failed to init FS` / `SoftSIM failed to update profile`, which is misleading — NVS mounted
fine; `ss_init_fs()` found an empty cache because the template was never written.

`apps/*/pm_static.yml` pins the TF-M storage partitions above `nvs_storage`.

### Application init flow

`apps/softsim` and `apps/throughput` both start from the Onomondo sample. Both guard two calls
with `#ifndef CONFIG_SOFTSIM_AUTO_INIT`:

- `nrf_softsim_init()` — the module's `SYS_INIT` already did this when auto-init is on
- `AT%CSUS=2` (select software SIM) — the module's `NRF_MODEM_LIB_ON_INIT` hook already sent it

Calling either unguarded with auto-init enabled double-initialises the filesystem, restarts a
running work queue, and the SIM never comes up. Keep the guards when copying these apps.

`apps/softsim` is built in *external profile* mode: on first boot `provision_softsim_from_serial()`
prompts on the board's console every 20 s (COM15 Feather / COM8 Icarus), `src/profile_serial.c`
collects the pasted hex string — terminated by either CR or LF, whichever arrives first — then it
provisions and reboots. A provisioned device skips this entirely, so re-provisioning requires
either an `ERASE_ALL` flash of `merged.hex` or a build with
`CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION=y`.

### Apps

| App | Build dir | Purpose |
|---|---|---|
| `apps/blinky` | `build` | toggles `led0`; toolchain smoke test |
| `apps/at_client` | `build-at` | raw AT shell over uart0. Its `Kconfig.sysbuild` sets `PARTITION_MANAGER` default n; `sysbuild.conf` overrides that back to `y`, without which the image is signed `--rom-fixed 0x50000` and MCUboot rejects it |
| `apps/softsim` | `build-softsim` | provisions the SoftSIM, attaches, then runs 3 Google reachability checks (DNS + TCP + HTTP HEAD) |
| `apps/nrf_cloud_coap_location` | `build-coap-loc` | nRF Cloud CoAP cell-tower location over SoftSIM; needs the device onboarded (see README) |
| `apps/memfault` | `build-memfault` | Memfault cellular demo over SoftSIM: coredumps, heartbeats, reboot reasons over HTTPS. Needs gitignored `profiles/memfault_key.conf` |
| `apps/throughput` | `build-throughput` | times a 100 KB HTTP download, prints band/RSRP/SNR; **loops forever, ~8 MB/h** — do not leave running on the PAYG SIM |

### Host scripts

- `New-SoftSimProfile.ps1` — encodes the TLV profile from raw credentials (tags: `01` IMSI,
  `02` ICCID, `03` OPc, `04` Ki, `05` KIC, `06` KID). Rarely needed: Monogoto's fulfilment CSV
  already contains the finished string.
- `New-IcarusBoard.ps1 -Name 'Icarus 3'` — factory-fresh Icarus to tracker map in one run:
  modem 1.3.7, next unused SIM from the Monogoto CSV, nRF Cloud onboarding (on `apps/at_client`,
  because the tracker's `uart_idle` kills the console on `AT+CFUN=4`), tracker + SoftSIM template
  flash, boot check, registry entry. Needs `build-at-icarus` built once. Refuses a board that
  already runs the tracker or holds a SIM filesystem.
- `secrets/boards.json` — board registry (name, device id, ICCID). `Get-TrackerHistory.ps1` reads
  its device list from here, so no IMEI lives in tracked source.
- `Get-SoftSimProfile.ps1` — Monogoto API client, only for the HEX-image route.
- `profiles/`, `secrets/` — the live profile and credentials, gitignored. `profiles/` holds the
  190-hex-char string to paste when provisioning.

## Modem AT gotchas

`AT%XBANDLOCK` persists in modem NVM, and the write happens on the transition **into**
`AT+CFUN=0`, not when the command returns OK. `CFUN=0 / XBANDLOCK=0 / CFUN=1` reads back as `""`
and looks successful while the old lock is still in NVM, returning on the next boot and stranding
the device at `+CEREG: 4` / `%XCBAND: 0`. Clearing needs a second `CFUN=0` to commit, ~2 s of
settling after each `CFUN=0`, and a readback verified across a hard reset.

PSM is aggressive (`TAU: 1800`): the device can be unreachable for up to 30 min. Expected for a
tracker, surprising mid-debug.

## Circuit Dojo's online docs are NCS 2.x

They predate this SDK and each difference fails silently: board target is
`circuitdojo_feather/nrf9160/ns` (not `circuitdojo_feather_nrf9160_ns`), MCUboot via
`SB_CONFIG_*`, DFU payload is `build/<app>/zephyr/zephyr.signed.bin` (not `app_update.bin`), APN
symbol is `CONFIG_LTE_LC_PDN_DEFAULT_APN` (not `CONFIG_PDN_DEFAULT_APN`), and Asset Tracker v2 is
replaced by `nrf/applications/asset_tracker_template`.
