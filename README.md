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

If you do flash over SWD again later, note that `nrfutil device program` defaults to
`chip_erase_mode=ERASE_ALL` — it erases all 1 MB plus UICR no matter how little the hex
spans, taking the provisioned SIM at `0xF0000` with it. Pass
`--options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE` for anything that is not this
one-time bring-up. A device wiped this way has no MCUboot at `0x0` and prints nothing at
all, which reads as dead hardware; `nrfutil device read --address 0x0 --bytes 16` returning
all `FF` is the tell.

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
reboots, and attaches. `LTE connected!` is the pass condition. Three Google reachability
checks follow it, each logging `check N/3 PASSED` after a DNS resolve, a TCP connect and an
`HTTP/1.1 301 Moved Permanently` reply from `google.com`.

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

## nRF Cloud CoAP location

`apps/nrf_cloud_coap_location` gets a cell-tower fix from nRF Cloud over CoAP. Verified on
this board: `Lat: 59.33, Lon: 17.99, Uncertainty: 395 m` (rounded here), ~13 s from reset, over the
SoftSIM.

The nRF9160 **cannot** use nRF Cloud's Provisioning Service — attestation-token claiming is
nRF91x1-only, and chasing it yields `Device not authorized` forever. That limit is only about
*claiming*. CoAP itself is supported on the 9160 (Nordic lists the CoAP API requirements as
"nRF91x1 or nRF9160", modem firmware **≥ 1.3.5** — check with `AT+CGMR`), reached through
**preconnect onboarding** instead. This is a one-time setup per device.

Everything below uses the NCS toolchain's Python, because there is no system Python on PATH:

```powershell
$py = "C:\ncs\toolchains\dcbdc366a1\opt\bin\python.exe"
```

The installer drives the device over AT, so it needs an app with an AT host running. Which app
depends on whether the SoftSIM is already provisioned:

> **Never flash `apps/at_client` at a board whose SoftSIM is provisioned.** It has no
> `pm_static.yml` at all, so Partition Manager places the TF-M storage partitions
> automatically — the exact condition that puts `tfm_otp_nv_counters` on `0xF0000` and
> destroys the SIM. On a *fresh* board it is fine, and it is the cleanest option there
> because it leaves the modem idle at `+CFUN: 0`.

On a provisioned board, don't reflash at all: `apps/softsim` already sets
`CONFIG_AT_HOST_LIBRARY=y`, so the running app answers AT on its own console and the installer
can use it directly. Put the modem offline first, on that same console:

```
AT+CFUN=4
```

Then, from `secrets\`:

```powershell
# Once per *account*, not per device -- a second board reuses the existing self_* CA,
# which nRF Cloud already trusts. Skip this if secrets\self_*_ca.pem exists.
& $py -m nrfcloud_utils.create_ca_cert -c SE -f self_

# Per device. --port is the board's console: COM15 Feather, COM8 Icarus.
# Give each board its own CSV so one does not overwrite the other's row.
& $py -m nrfcloud_utils.device_credentials_installer `
    --ca self_*_ca.pem --ca-key self_*_prv.pem `
    --id-str "nrf-" --id-imei -s -d --verify --coap `
    --port COM8 --rtscts-off --csv onboard-icarus.csv

& $py -m nrfcloud_utils.nrf_cloud_onboard --api-key <LEGACY_KEY> --csv onboard-icarus.csv
```

Three flags carry all the weight:

- **`--rtscts-off`** is mandatory. The tool turns RTS/CTS hardware flow control on by default
  and the Feather's uart0 has no RTS/CTS pins, so without it every command fails as
  `Failed to detect shell mode. Device does not respond to AT commands.` — while the same AT
  commands answer instantly from a terminal.
- **`--coap`** installs the CoAP root CA. CoAP and MQTT/HTTPS use *different* roots, so
  credentials installed for MQTT are silently useless here.
- **`--id-str "nrf-" --id-imei`** makes the certificate CN exactly the device ID the firmware
  presents (`CONFIG_NRF_CLOUD_CLIENT_ID_SRC_IMEI` + prefix `nrf-`). A mismatch is invisible
  until `nrf_cloud_coap_connect()` fails to authenticate.

The private key is generated **on the device** (the installer requests a CSR over AT), so no
key material ever reaches the host — there is nothing to delete afterwards. The CA, device
certificate and `onboard.csv` land in `secrets\`, which is gitignored.

`<LEGACY_KEY>` must be the **legacy nRF Cloud** API key from nrfcloud.com → User Account,
reached via the "Legacy App" link. `nrf_cloud_onboard` targets `https://api.nrfcloud.com/v1/`
and rejects a Memfault OAT with 401 — including the OAT that works for org/project-scoped
ground-fix calls.

There is no longer a way to pre-check the key: `GET /v1/account` now returns **410 Gone** for
any credential, good or bad, so it cannot distinguish them (verified 2026-09-16, with a key
that onboarded a device successfully seconds later). Judge by the onboarding call itself — it
reports `Onboarding status: SUCCEEDED` and a per-device `OK`.

Failure signatures, in the order you meet them:

| Symptom | Cause |
|---|---|
| `Connecting to nRF Cloud failed, error: -13` | credentials installed, device not onboarded yet |
| `error: -111`, `Device not authorized` | chasing the Provisioning Service; wrong path on a 9160 |
| `Failed to init FS` | `nvs_storage` moved off `0xf0000` — check `build-coap-loc\partitions.yml` |

That last one is worth expanding: `CONFIG_TFM_PARTITION_PROTECTED_STORAGE` must be **off**.
With PS enabled, Partition Manager puts a `tfm_ps` partition at `0xf0000` — exactly where the
SoftSIM filesystem lives — and pushes `nvs_storage` down to `0xe8000`. The app then mounts an
empty NVS and reports SoftSIM corruption that is really a moved partition.

## GNSS and nRF Cloud A-GNSS

`apps/gnss_agnss` is `nrf/samples/cellular/gnss` ported to the Feather. It pulls assistance
from nRF Cloud over CoAP (`coap.nrfcloud.com:5684`, sec tag `16842753`) on the same SoftSIM
that carries the data session — no second SIM, no separate bearer.

All figures below measured 2026-09-11 in Stockholm, open sky, `AT%XCOEX0=1,1,1565,1586`
active (without it the GPS antenna is electrically dead — see Board specifics).

### Time to first fix

| Start | Modem holds | TTFF | Assistance fetched |
|---|---|---|---|
| Cold, unassisted | nothing | **4 min 41 s** | — |
| Cold, A-GNSS | injected over CoAP | **12.8 – 17.6 s** (4 runs, mean 15.3 s) | ~5 KB every run |
| Warm | ephemeris still valid | **2.1 s** (3 consecutive runs, identical) | **none** |

Cold-start runs came from `overlay-ttff.conf`
(`CONFIG_GNSS_SAMPLE_MODE_TTFF_TEST_COLD_START=y`), which deletes ephemerides, almanac, iono
data, last good fix and GPS time before every run. Warm-start runs came from
`overlay-ttff-warm.conf`, identical but for that one symbol.

The warm sequence is the interesting one — a single capture, 60 s apart:

```
run 1  15.7 s   Requesting A-GNSS data  (cold: nothing in the modem yet)
run 2   4.1 s   no fetch
run 3   2.1 s   no fetch
run 4   2.1 s   no fetch
run 5   2.1 s   no fetch
```

One assistance fetch in five minutes. Runs 2-5 never touched the network.

### What that means for the tracker

**A-GNSS is not a per-fix cost.** Broadcast ephemeris stays usable for roughly two hours, so
a device reporting every 30 min fetches assistance about 12 times a day, not 48. Every other
wake is a 2.1 s fix with zero bytes.

**Cold-start numbers are the wrong ones to design around.** A tracker does not reboot between
fixes; it wakes from PSM with the modem's GNSS memory intact. 15 s is what it pays after power
loss or a long gap, not what it pays on a normal wake.

**The 7.5x difference is receiver-on time**, which dominates the energy budget of tracking far
more than the cellular side does.

### A-GNSS fetch cost

Two components, worth separating because only one recurs:

| | At boot | Session already up |
|---|---|---|
| "needed" to "requested" | 2.7 s (JWT sign + CoAP connect) | 1.5 ms |
| "requested" to injected | 1.2 – 1.8 s | 1.2 – 1.8 s |

The connect cost is once per boot, not once per fetch. `+CSCON: 1` to `+CSCON: 0` brackets
about 2 s of radio activity per cycle.

### Reporting fixes back

Assistance is a **download only**. The fix is computed on the device, and without an uplink
nothing about it ever leaves the board — `app.nrfcloud.com/#/locations` stays empty, which
reads as a provisioning failure when it is a missing call.

`CONFIG_GNSS_SAMPLE_LOCATION_UPLINK=y` (via `overlay-uplink.conf`) adds it:
`assistance_location_send()` posts each fix with `nrf_cloud_coap_location_send()`, reusing
the CoAP connection the assistance module already holds. Verified on hardware — three
positions 60 s apart, accuracy tightening 7.9 m to 2.7 m as tracking improved, all three on
the map.

Notes on the implementation:

- It lives in `assistance.c`, not `main.c`, because the connection and its `coap_connected`
  flag are already there.
- The transfer runs on `gnss_work_q`, the same queue as `assistance_request()`, so an uplink
  and a fetch can never be in flight on one connection at once.
- Sends are skipped when `date_time_now()` has no time yet: nRF Cloud **silently discards** an
  untimestamped position.
- `-EACCES` triggers one reconnect and retry. At `TAU: 1800` the DTLS session lapses across a
  PSM sleep routinely.
- The option `depends on !GNSS_SAMPLE_MODE_TTFF_TEST`, so a TTFF measurement run cannot be
  built with the uplink inflating it.

`CONFIG_GNSS_SAMPLE_LOCATION_UPLINK_INTERVAL` rate-limits the rest — continuous mode produces
a PVT every second, so without it the sample would send one CoAP message per second.

### Fix quality

Consecutive cold starts scattered 9.4 m horizontally and 6 m vertically; across a longer
session with degrading sky view, 10.9 m / 14.6 m. Accuracy tracked satellite count closely
(10 sats / HDOP 1.06 at best, 5 sats / HDOP 3.4 at worst).

Worth noting: **TTFF did not degrade with sky view, accuracy did.** The fastest cold run
(12.8 s) happened on only 5 satellites. With ephemerides pre-loaded the modem no longer needs
enough signal to demodulate the navigation message, only enough to track — so A-GNSS buys
acquisition robustness, not precision.

### Build

```powershell
# Continuous tracking, reports fixes to nRF Cloud
west build -b circuitdojo_feather/nrf9160/ns -d build-agnss apps\gnss_agnss `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim" `
     "-DOVERLAY_CONFIG=C:/path/to/nRF9160/apps/gnss_agnss/overlay-uplink.conf"

# Warm-start TTFF measurement (no uplink — Kconfig forbids it in TTFF mode)
west build -b circuitdojo_feather/nrf9160/ns -d build-agnss-ttff apps\gnss_agnss `
  -- "-DEXTRA_ZEPHYR_MODULES=C:/path/to/nRF9160/modules/onomondo-softsim" `
     "-DOVERLAY_CONFIG=C:/path/to/nRF9160/apps/gnss_agnss/overlay-ttff-warm.conf"
```

Swap `overlay-ttff-warm.conf` for `overlay-ttff.conf` to measure the cold path instead.

`OVERLAY_CONFIG` persists in that build dir's CMakeCache and is invisible until someone
creates a fresh build dir — the same trap as `-DEXTRA_ZEPHYR_MODULES`. Check
`build-*/gnss_agnss/zephyr/.config` if a build behaves like the wrong overlay.

Capture a run with `.\monitor.ps1 -Log warmstart.log`; every line is prefixed with seconds
since the script started, so the timing survives.

## Memfault

`apps/memfault` is Memfault's cellular demo app
(`modules/lib/memfault-firmware-sdk/examples/nrf-connect-sdk/cellular/memfault_demo_app`)
ported to the Feather over SoftSIM. `src/` and `config/` are copied unmodified so they can
be re-synced upstream; every board-specific change is in `CMakeLists.txt`, `prj.conf`,
`sysbuild.conf` and `pm_static.yml`.

Verified end to end 2026-09-11: coredumps, reboot reasons and heartbeats reach the
"nRF Project" Memfault project over HTTPS through the SoftSIM. A crash cycle looks like:

```
uart:~$ mflt test assert
<inf> mflt: Reset Cause Stored: 0x8001
uart:~$ mflt get_core
<inf> mflt: Has coredump with size: 7712
uart:~$ mflt post_chunks
<inf> mflt: Data posted successfully, 4966 bytes sent
uart:~$ mflt get_core
<inf> mflt: No coredump present!
```

The app also uploads on its own — it logs `Periodic background upload scheduled -
initial delay=913s period=3600s` at boot.

**Memfault needs no onboarding.** Unlike nRF Cloud CoAP, there are no certificates and no
device claiming: a project key compiled in, and the IMEI as the device serial (set at
runtime by `prv_init_device_info()` in `src/main.c`, which is what
`CONFIG_MEMFAULT_NCS_DEVICE_ID_RUNTIME` enables). The key is an ingestion credential, so it
lives in the gitignored `profiles/memfault_key.conf`:

```
CONFIG_MEMFAULT_NCS_PROJECT_KEY="<Memfault -> Settings -> General -> Project Key>"
```

`CMakeLists.txt` appends that to `OVERLAY_CONFIG` and fails the build if it is missing,
rather than letting the device run and have every upload rejected.

### Four things that bite on this board

**Hardfaults produce no coredump on an `/ns` build.** `mflt test hardfault` answers
`HardFaults are handled by TF-M, no coredump will be collected` and reboots. The fault
escalates into the secure world before Memfault's handler runs. Use `mflt test assert`
(or another non-secure-side fault) to exercise coredump capture.

**The `mflt` commands are silent by default, while working perfectly.**
`mflt get_device_info`, `mflt post_chunks` and `mflt get_core` print nothing at all, which
looks like a dead feature — the first uploads here could only be confirmed from the
Memfault API. Two independent causes, and fixing either alone changes nothing:

- the SoftSIM overlay drops `CONFIG_LOG_DEFAULT_LEVEL` to 1, and `CONFIG_MEMFAULT_LOG_LEVEL`
  follows it, so `MEMFAULT_LOG_INFO` is filtered before it is emitted;
- what survives goes through Zephyr's deferred LOG subsystem to the UART backend while the
  Memfault shell owns that same UART (`CONFIG_SHELL_LOG_BACKEND=n`).

`prj.conf` sets `CONFIG_MEMFAULT_LOG_LEVEL_INF=y` **and**
`CONFIG_MEMFAULT_PLATFORM_LOG_FALLBACK_TO_PRINTK=y`. `mflt test heartbeat` is the
misleading clue: it prints via `shell_print` and always worked.

**Upstream's NCS version check breaks under sysbuild.** The demo calls
`find_package(Ncs)` before `find_package(Zephyr)`; `NcsConfig.cmake` then reads the *CMake*
variable `ZEPHYR_BASE` (not the environment one) and includes
`/cmake/modules/version.cmake`, failing with `NCS Version not found, please contact
Memfault support!`. This port reads `nrf/VERSION` directly instead.

**The littlefs demo is removed.** `CONFIG_FILE_SYSTEM_LITTLEFS` wants a storage partition on
internal flash, which here is the SoftSIM's `nvs_storage` at `0xF0000`. It only feeds a
filesystem-utilization metric — not worth the collision.

### Symbolication

Traces arrive as **"Assert at Unknown Location"** until the build's symbol file is uploaded.
Upload `build-memfault\memfault\zephyr\zephyr.elf` for the matching software version
(`mflt get_device_info` prints it, e.g. `0.0.1+b434aa`) via Memfault → Settings → Software →
Symbol Files, or with `memfault-cli` and an organization auth token. The project key is an
ingestion credential only and cannot upload symbols.

## Known gaps

- **No telemetry endpoint.** `apps\softsim\src\main.c` proves the data path with three Google reachability checks and then idles. The upstream sample's `Hello from Onomondo!` UDP send to a placeholder `1.2.3.4:4321` was removed — it failed by design and proved nothing. A real endpoint is still needed for actual tracker payloads.
- **Every serial flash needs the button dance.** Adding mcumgr/SMP to `prj.conf` would let `zephyr-tools -b` reset the board into DFU instead. Not needed for SWD flashes.
- **Re-provisioning is not obvious.** The app only prompts for a profile when `nrf_softsim_check_provisioned()` is false, so a provisioned device boots straight to the modem. To start over, either re-flash `merged.hex` with `chip_erase_mode=ERASE_ALL` or build with `CONFIG_SOFTSIM_FACTORY_RESET_ON_PROVISION=y`.
- **PSM is aggressive.** `TAU: 1800` means the device is unreachable for up to 30 min between wakeups. Fine for a tracker, surprising when debugging.

## Next steps

1. Point the UDP socket at a real endpoint and confirm data lands (Monogoto's console shows per-Thing data usage).
2. ~~Check the modem firmware version~~ — done, `AT+CGMR` reports `mfw_nrf9160_1.3.7`, above the 1.3.5 that nRF Cloud CoAP requires.
3. Add mcumgr to the app so serial flashing stops needing the buttons.
4. **Motion-triggered wake-up from the accelerometer** — see below.
5. Bring up `asset_tracker_template` on the Feather. The cloud endpoint question is now
   settled: **nRF Cloud over CoAP**, not MQTT — see GNSS and nRF Cloud A-GNSS above for why
   CoAP is proven on this board. Start by letting nRF Cloud draw the map, then pull the
   positions out to `tools/feather_map.py` over the nRF Cloud REST API once that works.
   Dropping `CONFIG_NRF_CLOUD=n` also removes the `check_modules_ready()` hang: that bug
   only exists because disabling nRF Cloud disables `APP_FOTA`, leaving `fota_ready` with
   no publisher. Still needed either way: carrying the SoftSIM partition layout across. It
   does *not* need a board overlay for the LIS2DH: the board DTS already declares
   `lis2dh@18` on i2c1 with `irq-gpios = <&gpio0 29 GPIO_ACTIVE_HIGH>`.

### Motion-triggered wake-up

The point of a tracker is to stay asleep until it moves. `apps/accel` polls, which proves
the sensor works but burns power continuously; the goal is for the LIS2DH to hold the
nRF9160 asleep and raise a line only on movement.

**Hardware prerequisite, and it is a blocker:** the interrupt line only reaches the SoC if
**JMP3 is soldered** on the Feather. Circuit Dojo's own accelerometer sample says so
outright. Without it the sensor still reads over I2C but its INT pin goes nowhere, so
hardware wake is impossible and polling is the only option — which defeats the purpose.
Confirm that jumper before designing around interrupts.

What the parts look like:

- **Trigger type.** The Zephyr driver supports `SENSOR_TRIG_DELTA` (any-motion / slope) and
  `SENSOR_TRIG_TAP` — see `zephyr/drivers/sensor/st/lis2dh/lis2dh_trigger.c:184`.
  `SENSOR_TRIG_DELTA` is the one for "it moved".
- **Sensitivity.** `SENSOR_ATTR_SLOPE_TH` sets the acceleration threshold and
  `SENSOR_ATTR_SLOPE_DUR` how long it must persist before the interrupt fires
  (`lis2dh_trigger.c:299,337`). Tuning these against a real enclosure is the actual work —
  too sensitive and it wakes on a passing lorry, too coarse and a theft is missed.
- **Kconfig.** `CONFIG_LIS2DH_TRIGGER_GLOBAL_THREAD=y` (or `OWN_THREAD` to keep the
  callback off the system workqueue).
- **Keep the TF-M settings from `apps/accel`.** `CONFIG_TFM_SECURE_UART=n` plus
  `CONFIG_TFM_LOG_LEVEL_SILENCE=y`, or i2c1 bus-faults — see the Serial-Box explanation in
  that app's `prj.conf`.
- **The power path is the real design question**, and is untested here. Deep sleep on the
  nRF9160 means System OFF, woken by a GPIO SENSE edge on `gpio0 29`; that resets rather
  than resumes, so the app must treat a motion wake as a boot and check the reset reason.
  How this composes with the modem's PSM (`TAU: 1800`) needs measuring, not guessing — the
  modem and the app sleep independently and the radio dominates the power budget.
