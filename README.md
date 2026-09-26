# nRF9160 Feather

Firmware for a Circuit Dojo nRF9160 Feather. Goal: a cellular asset tracker.
Current state: **cellular is up.** A Monogoto SoftSIM provisions and registers on the
network — no physical SIM, no SIM slot used.

## Build and flash

```powershell
. .\env.ps1
west build -b circuitdojo_feather/nrf9160/ns -d build apps\blinky
.\flash.ps1
```

Before `flash.ps1`, put the board in bootloader mode:

1. **Hold** MODE
2. **Tap** RST while still holding MODE
3. **Keep holding** MODE until the blue LED lights solid

Add `--pristine` to `west build` only after changing `sysbuild.conf`, the board target, or Kconfig defaults. Normal source edits rebuild in ~30 s.

Watch the console with any serial terminal on **COM15 @ 115200**, or the VS Code Serial Monitor.

## SoftSIM (Monogoto)

`apps\softsim` runs the Onomondo SoftSIM stack against a Monogoto profile. Confirmed
working 2026-08-04: registered roaming on Tele2 Sweden (`+COPS: 0,2,"24007",7`, LTE-M),
attach in ~9 s.

### Getting a SIM

1. Create an account at [hub.monogoto.io](https://hub.monogoto.io/).
2. Order **Global SIM Pay As You Go** ($1 per SIM) as a **SoftSIM**, with **Profile E Global**
   (MCC/MNC 295/05). Pay by card in the Hub.
3. **Wait 1–2 days.** You can't provision anything until Monogoto's fulfilment email arrives.
   The SIMs may already show up in the Hub as Things before then, but the credentials only
   come in that email.
4. The email attaches a CSV with one row per SIM: `ICCID, IMSI, MSISDN, KI, OPC, Profile`. The
   `Profile` column is the finished 190-hex-char string you paste at the provisioning prompt.
   Keep the CSV out of git, because it contains each SIM's Ki and OPc.
5. Continue with [Build and provision](#build-and-provision) below.

Monogoto's own [SoftSIM page](https://monogoto.io/softsim/) describes a different route: feed
those credentials to the SoftSIM API ([developer.monogoto.io](https://developer.monogoto.io/overview))
to generate a per-chip `.hex`, then flash it with nRF Connect Programmer. This repo skips that
step. It hands the CSV's `Profile` string to the Onomondo stack's serial provisioning, so no
API key is needed. `Get-SoftSimProfile.ps1` implements the `.hex` route if you want it.

### The one thing that will waste your afternoon

**A fresh SoftSIM cannot be brought up over serial DFU.** The SIM's filesystem needs an
8184-byte directory template (`modules\onomondo-softsim\lib\profile\template.bin`) sitting
in the `nvs_storage` partition at `0xF0000`. `flash.ps1` writes only the MCUboot
application slot, so that partition stays empty and you get:

```
<err> softsim: Failed to init FS
<err> softsim: SoftSIM failed to update profile
```

which is misleading — NVS mounted fine. `ss_init_fs()` returns `ss_list_empty(&fs_cache)`,
and the cache is empty because the DIR entry was never written.

Fix it once over SWD with `merged.hex`, which carries MCUboot + TF-M + app + template
together (it spans `0x0`–`0xF1FF8`):

```powershell
. .\env.ps1
nrfutil device program --firmware .\build-softsim\merged.hex --options chip_erase_mode=ERASE_ALL
nrfutil device reset
```

This is a **one-time** step. It also installs MCUboot, so every later app update goes back
over `flash.ps1` serial DFU without the probe.

### Build and provision

```powershell
. .\env.ps1
west build -b circuitdojo_feather/nrf9160/ns -d build-softsim apps\softsim `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim"
```

The `-DEXTRA_ZEPHYR_MODULES` flag is **required** — `modules\onomondo-softsim` is out-of-tree
and not in any west manifest, so nothing else registers it. Without it the build fails at
`attempt to assign the value 'y' to the undefined symbol SOFTSIM_BUNDLE_TEMPLATE_HEX`. It must
be quoted in PowerShell, or the drive-letter colon splits the argument in two.

To update the app on an already-provisioned device without disturbing the SIM, flash
`build-softsim\softsim\zephyr\zephyr.signed.hex` over SWD — it spans `0x10000`–`0x4E048`, the
MCUboot slot only, touching neither the bootloader nor `nvs_storage`. Flashing `merged.hex`
would rewrite `nvs_storage` with a **blank** template and wipe the provisioned profile.

The app is built in *external profile* mode (`CONFIG_SOFTSIM_STATIC_PROFILE_ENABLE` off), so
on first boot it asks for the profile every 20 s:

```
Transfer SoftSIM profile using serial COM port, terminate by newline character (return key)
```

Paste the 190-hex-char profile string on COM15 @ 115200 and press Enter. It provisions,
reboots, and attaches. `LTE connected!` is the pass condition — the
`Failed to transmit UDP packet` that may follow is expected, because `main.c` sends to a
placeholder `1.2.3.4:4321`.

Verify from the same console: `AT+CPIN?` → `READY`, `AT+CIMI` → the IMSI, `AT%XICCID` →
the ICCID, `AT+COPS?` → the operator.

### Measured throughput

`apps\throughput` is a probe that times a 100 KB HTTP range-download and prints the rate
alongside the serving band and radio conditions, looping so the band can be changed over AT
between runs. Measured 2026-08-04, Stockholm, Tele2 roaming:

| Band | RAT | RSRP | SNR | Rate | Notes |
|---|---|---|---|---|---|
| 3 (1800) | LTE-M | −116 dBm | −5 dB | **84 kbps** | fastest, despite the worst signal (n=1) |
| 20 (800) | LTE-M | −87…−90 dBm | −2…3 dB | **32–37 kbps** | 3 consistent samples |
| 8 (900) | NB-IoT | −75 dBm | +10 dB | **18 kbps** | best signal, slowest — NB-IoT ceiling |

**Signal strength does not predict throughput here.** Band 8 has 40 dB more RSRP than band 3
and is 4.7× slower, because Tele2 runs NB-IoT on 900 and NB-IoT has a hard protocol ceiling.
Between the two LTE-M bands, the weaker one (3) was faster — at these rates cell loading and
scheduling matter more than raw RSRP. The band 3 figure is a single sample; treat it as
indicative, not settled.

Bands 28 (700) and 1 (2100) never attached — not deployed for LTE-M/NB-IoT here, or not open
to this roaming agreement.

### Band locking will strand the device if you get it wrong

`AT%XBANDLOCK` **persists in modem NVM**, and the write happens on the transition into
`AT+CFUN=0` — not when the command returns OK. Clearing it with

```
AT+CFUN=0
AT%XBANDLOCK=0
AT+CFUN=1
```

clears the *running* value, reads back as `""` and looks completely successful, but the old
lock is still in NVM and comes back on the next boot — leaving the device locked to a band
that may not exist locally, with `+CEREG: 4` and `%XCBAND: 0` forever. Add a second
`AT+CFUN=0` after clearing to commit, then verify the readback **across a reset**:

```
AT+CFUN=0 ; AT%XBANDLOCK=0 ; AT+CFUN=1 ; AT+CFUN=0 ; AT+CFUN=1
```

Also allow ~2 s after `AT+CFUN=0` before touching `%XBANDLOCK`; the modem returns OK before it
has finished powering down, and a lock change issued too early is silently dropped.

### What the link can carry

At ~35 kbps sustained on LTE-M, with 100–500 ms RTT that spikes to seconds out of PSM:

| Use case | Verdict |
|---|---|
| Telemetry, GPS, sensors | trivial |
| Voice — Codec2 (0.7–3.2 kbps) or Opus narrowband (8–16 kbps) | works, one-way or buffered |
| Photos — QVGA JPEG ~15 KB / VGA ~40 KB | ~3 s / ~9 s each |
| Live video, any resolution | no |
| Buffered video clip, store-and-forward | minutes of upload per clip |
| Music-quality audio (64+ kbps) | no |

The hardware bites before the link does: no camera interface, no video codec, 256 KB RAM.
A camera needs an external SPI module that emits JPEG itself (OV2640-class); audio can use the
on-chip PDM or I²S. Sustained streaming is also a power and cost problem — 16 kbps is 7.2 MB/h,
and LTE-M TX peaks at 200–250 mA.

### Where the profile comes from

Monogoto's fulfilment email attaches a CSV whose **`Profile` column is already the finished
TLV string**. The `/softsim/nordic/generate` API and `Get-SoftSimProfile.ps1` are only for
the HEX-image route — neither is needed to bring a single SIM up.

**Take the ICCID from the `Profile` string or from `AT%XICCID`, not from the console or the
CSV's `ICCID` column.** The Hub console and the CSV column both truncate it to 19 digits. The
real ICCID has 20, including a Luhn check digit. Inside `Profile` it's TLV tag `02`, in
swapped-nibble BCD. `New-SoftSimProfile.ps1` F-pads the
missing nibble and silently produces a different EF.ICCID — the last byte comes out
`F<digit>` instead of the swapped-BCD check digit. The modem reports the 20-digit form via `AT%XICCID`.

No APN configuration is needed — attach works with nothing set. Monogoto's APN is
`go.mono` if something later needs the context named explicitly; in NCS 3.4 the symbols are
`CONFIG_LTE_LC_PDN_MODULE` / `CONFIG_LTE_LC_PDN_DEFAULTS_OVERRIDE` /
`CONFIG_LTE_LC_PDN_DEFAULT_APN`. Note the `LTE_LC_` prefix — the NCS 2.x `CONFIG_PDN_*`
form is silently ignored, same trap as the MCUboot one below.

## Layout

```
env.ps1                   PATH / ZEPHYR_BASE / NRFUTIL_HOME for the C:\ncs toolchain
flash.ps1                 newtmgr serial DFU to COM15 (override with -Port / -Image)
New-SoftSimProfile.ps1    encode a TLV profile from raw credentials; -SelfTest verifies it
Get-SoftSimProfile.ps1    Monogoto API client (only needed for the HEX-image route)
tools\newtmgr\            newtmgr.exe, SHA256-verified against the Zephyr Tools manifest
modules\onomondo-softsim\ SoftSIM stack, out-of-tree (not pulled in by west)
apps\blinky\
  prj.conf                GPIO + console on uart0
  sysbuild.conf           SB_CONFIG_BOOTLOADER_MCUBOOT=y
  src\main.c              toggles the led0 alias every 500 ms
apps\at_client\           raw AT shell over uart0
apps\throughput\          times a 100 KB HTTP download; prints band + RSRP + SNR per run
apps\softsim\
  prj.conf                external-profile mode, modem + LTE link control
  sysbuild.conf           partition manager + bundled template hex + MCUboot
  pm_static.yml           TF-M storage layout
  overlay-mcuboot.conf    re-sizes the TF-M partition; must apply after the module overlay
  src\main.c              provisions over serial, then attaches and sends UDP
build\, build-softsim\    generated; safe to delete
profiles\, secrets\       real SIM credentials — gitignored, never commit
```

## Environment

| | |
|---|---|
| SDK | nRF Connect SDK **v3.4.0 LTS** at `C:\ncs\v3.4.0` (Zephyr 4.4.0) |
| Toolchain | `C:\ncs\toolchains\dcbdc366a1` — west 1.5.0, nrfutil 8.1.1, Zephyr SDK |
| Board target | `circuitdojo_feather/nrf9160/ns` |
| Board support | upstream Zephyr, `zephyr/boards/circuitdojo/feather/` |
| Flash | MCUboot serial DFU over the CP2102N on **COM15**; J-Link on SWDIO/SWCLK for `merged.hex` |
| Debug probe | J-Link Plus Compact — wired to the SWD pins |
| SIM | Monogoto SoftSIM, Profile E Global (MCC/MNC 295/05), APN `go.mono`; $1 Pay As You Go, ordered via hub.monogoto.io |
| Editor | nRF Connect for VSCode + Circuit Dojo Zephyr Tools |

Zephyr Tools is installed for its `newtmgr` binary only. **Do not run its Setup command** — it would install a second SDK outside `C:\ncs`.

## Board specifics

The Feather's devicetree already provides everything blinky needs:

| Alias | Node | Detail |
|---|---|---|
| `led0` | `blue_led` | gpio0 pin 3, `GPIO_ACTIVE_LOW` — the D7 blue LED |
| `sw0` | `button0` | gpio0 pin 12, pull-up, active low — the MODE button |
| `accel0` | `lis2dh` | on-board accelerometer, useful for the tracker |
| — | `zephyr,uart-mcumgr = &uart0` | the DFU transport |

Source: `C:\ncs\v3.4.0\zephyr\boards\circuitdojo\feather\circuitdojo_feather_nrf9160_common.dtsi`

## Circuit Dojo's docs are written for NCS 2.x

[docs.circuitdojo.com](https://docs.circuitdojo.com/nrf9160-feather/) predates this SDK. Four things differ and each one silently produces a broken build or an image the bootloader rejects:

| Their docs (NCS 2.x) | This project (NCS 3.4) |
|---|---|
| `circuitdojo_feather_nrf9160_ns` | `circuitdojo_feather/nrf9160/ns` |
| `CONFIG_BOOTLOADER_MCUBOOT=y` in `prj.conf` | `SB_CONFIG_BOOTLOADER_MCUBOOT=y` in `sysbuild.conf` |
| `build/zephyr/app_update.bin` | `build/blinky/zephyr/zephyr.signed.bin` |
| `CONFIG_PDN_DEFAULT_APN` | `CONFIG_LTE_LC_PDN_DEFAULT_APN` |
| Asset Tracker v2 | `nrf/applications/asset_tracker_template` |

The Kconfig-vs-sysbuild one is the nastiest: the old symbol is simply ignored under sysbuild, so the build succeeds and produces an unsigned image that the Feather's bootloader refuses. The PDN one fails the same way — silently, since an unknown `CONFIG_` symbol is not an error.

## Build output reference

For blinky, a clean build produces:

| Artifact | Size |
|---|---|
| `build\blinky\zephyr\zephyr.bin` (app alone) | 22.4 KB |
| `build\blinky\zephyr\zephyr.signed.bin` (TF-M + app, signed — **this is what gets flashed**) | 278.5 KB |
| `build\mcuboot\zephyr\zephyr.hex` (needs a debug probe) | 139.2 KB |

The signed image is large because an `/ns` build bundles TF-M's secure image alongside the app. That is expected, not bloat.

First build takes 10+ minutes — it compiles TF-M and MCUboot. Incremental builds are ~30 s.

## Known gaps

- **The UDP payload goes nowhere.** `apps\softsim\src\main.c` sends `Hello from Onomondo!` to a placeholder `1.2.3.4:4321` every 150 s, so the send fails by design. Needs a real endpoint.
- **Every serial flash needs the button dance.** Adding mcumgr/SMP to `prj.conf` would let `zephyr-tools -b` reset the board into DFU instead. Not needed for SWD flashes.
- **Re-provisioning is not obvious.** The app only prompts for a profile when `nrf_softsim_check_provisioned()` is false, so a provisioned device boots straight to the modem. To start over, either re-flash `merged.hex` with `chip_erase_mode=ERASE_ALL` or build with `CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION=y`.
- **PSM is aggressive.** `TAU: 1800` means the device is unreachable for up to 30 min between wakeups. Fine for a tracker, surprising when debugging.

## Next steps

1. Point the UDP socket at a real endpoint and confirm data lands (Monogoto's console shows per-Thing data usage).
2. Check the modem firmware version against what NCS 3.4 expects.
3. Add mcumgr to the app so serial flashing stops needing the buttons.
4. Bring up `asset_tracker_template` on the Feather — needs a board overlay for the LIS2DH and a cloud endpoint decision (nRF Cloud vs plain MQTT vs CoAP), plus carrying the SoftSIM partition layout across.