# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Firmware for a Circuit Dojo nRF9160 Feather, targeting a cellular asset tracker. Cellular is
up: a Monogoto SoftSIM (no physical SIM) provisions and registers. `README.md` carries the
hardware bring-up narrative and measured results; this file covers commands and structure.

There is no test suite, linter, or CI — the only automated check is
`.\New-SoftSimProfile.ps1 -SelfTest`, which verifies the EF.IMSI/EF.ICCID encoders against the
upstream reference profile.

## Environment

Everything runs from PowerShell with the NCS toolchain dot-sourced first:

```powershell
. .\env.ps1     # PATH, ZEPHYR_BASE, NRFUTIL_HOME for C:\ncs\v3.4.0 + C:\ncs\toolchains\dcbdc366a1
```

nRF Connect SDK **v3.4.0 LTS** (Zephyr 4.4.0). Board target `circuitdojo_feather/nrf9160/ns`
— the `/ns` split means every build also compiles TF-M, so a first build takes 10+ minutes and
incrementals ~30 s. Serial console is **COM15 @ 115200**.

## Build

Each app has its own build directory; `-d` is always passed explicitly.

```powershell
west build -b circuitdojo_feather/nrf9160/ns -d build          apps\blinky
west build -b circuitdojo_feather/nrf9160/ns -d build-at       apps\at_client
west build -b circuitdojo_feather/nrf9160/ns -d build-softsim  apps\softsim `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
west build -b circuitdojo_feather/nrf9160/ns -d build-throughput apps\throughput `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
```

`-DEXTRA_ZEPHYR_MODULES` is **mandatory for any SoftSIM app**. `modules/onomondo-softsim` is
out-of-tree and in no west manifest, so nothing else registers it; without the flag the build
dies on the undefined `SOFTSIM_BUNDLE_TEMPLATE_HEX`. Quote the whole argument or PowerShell
splits it at the drive-letter colon. The flag persists only in that build dir's CMakeCache, so
it is invisible until someone creates a fresh build dir.

`--pristine` is needed only after changing `sysbuild.conf`, the board target, or Kconfig
defaults. Normal source edits rebuild incrementally.

## Flash

Two paths, and picking the wrong one destroys the SIM provisioning.

**Serial DFU (normal app updates)** — writes the MCUboot app slot only. Board must be in
bootloader mode: hold MODE, tap RST, keep holding MODE until the blue LED is solid.

```powershell
.\flash.ps1 -Image .\build-softsim\softsim\zephyr\zephyr.signed.bin
```

`flash.ps1` defaults to blinky's image; pass `-Image` for anything else (`-Port` to override
COM15).

**SWD (J-Link)** — the only way to write outside the app slot.

```powershell
nrfutil device program --firmware .\build-softsim\merged.hex --options chip_erase_mode=ERASE_ALL
nrfutil device reset
```

Which hex to use on a provisioned device:

| Artifact | Spans | Effect |
|---|---|---|
| `build-softsim\merged.hex` | `0x0`–`0xF1FF8` | MCUboot + TF-M + app + **blank** SIM template — wipes provisioning |
| `build-softsim\softsim\zephyr\zephyr.signed.hex` | `0x10000`–`0x4E048` | app slot only — SIM survives |

`merged.hex` is for the one-time bring-up of an unprovisioned device (see README). After that,
use `zephyr.signed.hex` over SWD or `zephyr.signed.bin` over serial. Verify the address range of
any hex before flashing a provisioned board.

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
prompts on COM15 every 20 s, `src/profile_serial.c` collects the pasted hex string, then it
provisions and reboots. A provisioned device skips this entirely, so re-provisioning requires
either an `ERASE_ALL` flash of `merged.hex` or a build with
`CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION=y`.

### Apps

| App | Build dir | Purpose |
|---|---|---|
| `apps/blinky` | `build` | toggles `led0`; toolchain smoke test |
| `apps/at_client` | `build-at` | raw AT shell over uart0; sets `PARTITION_MANAGER` default n in `Kconfig.sysbuild` |
| `apps/softsim` | `build-softsim` | provisions the SoftSIM, attaches, sends UDP to a placeholder `1.2.3.4:4321` |
| `apps/throughput` | `build-throughput` | times a 100 KB HTTP download, prints band/RSRP/SNR; **loops forever, ~8 MB/h** — do not leave running on the PAYG SIM |

### Host scripts

- `New-SoftSimProfile.ps1` — encodes the TLV profile from raw credentials (tags: `01` IMSI,
  `02` ICCID, `03` OPc, `04` Ki, `05` KIC, `06` KID). Rarely needed: Monogoto's fulfilment CSV
  already contains the finished string.
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
