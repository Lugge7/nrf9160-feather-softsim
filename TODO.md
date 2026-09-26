# TODO

Open work across both boards. Ranked: the first item is the only one that still makes the
tracker unreliable in the field; the rest are papercuts and housekeeping.

Last reviewed 2026-09-24, after a second modem outage and after the map was found to freeze
silently whenever a board went quiet for longer than the pull window.

Firmware items live in the Asset Tracker Template workspace at `..\att` (a sibling of this repo),
not in this repo. Note that workspace's `origin` is Nordic's upstream, so nothing here should be
committed there — see the note at the bottom.

---

## 1. Escalate when the cloud will not connect  *(att: `app/src/modules/network`)*

**A wedged modem currently costs a day of downtime, and has done so twice in six days.**

| Outage | Duration | Ended by |
|---|---|---|
| 09-19 20:11 → 09-20 10:27 | 14 h | manual reset |
| 09-21 10:12 → 09-22 18:31 | 32 h | **recovered on its own** |

Both times it blinked dim red throughout and flushed its buffered samples on reconnect, so
nothing was lost — it just arrived a day late. Battery at dropout was 4.04 V on the first, so
neither was a power failure, and the SIM was never the problem.

That the second cleared itself shapes the fix: the modem is not always permanently wedged, so
rung 1 below would likely have caught both and the reboot is a backstop rather than the main
mechanism. It also confirms these are occasional rather than chronic — outside those two
windows the device reports every hour, all night, without missing a cycle.

Three things combine to make it unrecoverable:

- The cloud backoff is linear and capped — `APP_CLOUD_BACKOFF_INITIAL_SECONDS=60`,
  `_LINEAR_INCREMENT_SECONDS=60`, `_MAX_SECONDS=3600` — so it retries hourly, forever, against
  a PDN that is already dead. Retrying CoAP cannot fix the layer underneath it.
- Nothing escalates. There is no reboot-after-N-failures and no `CFUN` cycle anywhere in the
  network module; grep its Kconfig and the option does not exist.
- The watchdogs cannot see it. `APP_CLOUD_WATCHDOG_TIMEOUT_SECONDS=180` and
  `APP_NETWORK_WATCHDOG_TIMEOUT_SECONDS=600` fire only when a thread stops feeding `task_wdt`,
  and a loop that is contentedly backing off feeds normally. A wedged modem looks healthy.

**Wanted:** a ladder, each rung tried only after the one before it has failed.

1. N consecutive failed connects (start with N = 3, so ~3-6 min, not 14 h) → `AT+CFUN=0`,
   settle, `AT+CFUN=1`, re-attach.
2. Still failing after M cycles → `sys_reboot()`.

Both rungs behind Kconfig with the escalation off by default, so the template's own behaviour is
unchanged and this stays a local policy rather than a fork of upstream semantics.

**Testing:** force it with `AT+CFUN=4` (flight mode) from the shell — the cloud module starts
failing while the app stays up, which is the exact shape of the real fault. Confirm rung 1 fires
on schedule, then hold the fault and confirm rung 2 does. Watch the LED: dim red 250 ms on /
2000 ms off is `STATE_DISCONNECTED_WAITING` and means the app is alive, not crashed.

**Cost:** roughly an hour, most of it waiting on the test cycles.

**Do not** shorten `BACKOFF_MAX_SECONDS` instead and call it fixed. That makes it retry a dead
PDN more often, which is more radio for the same outage — worse on a PAYG SIM and worse on
battery.

---

## 2. Refresh the Monogoto credentials  *(this repo: `secrets\monogoto.json`)*

`console.monogoto.io/Auth` returns **`Access denied`** for the stored username and password as of
2026-09-20. Two consequences: the SIM side cannot be checked when a board goes quiet — which is
exactly when it would be most useful — and `Get-SoftSimProfile.ps1` cannot re-provision a
SoftSIM until it is fixed.

Only one attempt was made, deliberately: repeated failed logins risk locking the account. Get
fresh credentials from the Monogoto console before retrying.

Provisioning itself is not blocked — the fulfilment CSV in the repo root carries the finished
`ICCID,IMSI,MSISDN,KI,OPC,Profile` rows for both SIMs, which is the route
`New-SoftSimProfile.ps1` takes anyway. What the dead login costs is the *live* SIM status, which
is the one thing worth having when a board goes quiet and the only remote check that could tell
a wedged modem from a subscription problem.

That CSV is a secrets file sitting outside `secrets\`, and it was not covered by `.gitignore`
until 2026-09-24. `KI` and `OPC` are the SIM authentication keys and this repo's remote is
public. It is ignored now (`/*.csv` plus a name match) and `git grep` confirms nothing tracked
ever carried those headers, so nothing leaked — but the file still belongs in `secrets\`.

---

## 3. Show boards that have gone quiet  *(this repo: `New-TrackerMap.ps1`)*

**The dangerous half of this is fixed** (commit `0613131`). It was not a papercut: when the
Icarus went quiet for 32 h its last fix aged out of the 24 h window, `Get-TrackerHistory.ps1`
correctly wrote an empty `track.json`, and `New-TrackerMap.ps1` *threw* on it. The watch job
logged the exception 575 times over 15.7 h and kept serving the last good page — a frozen map
with a ticking clock and no sign its data had stopped. An empty window now renders a real page
with an amber note saying so.

**What remains is the cosmetic half.** A board with no fixes in the window still vanishes from
`DEVICES` entirely, so "offline for two days" and "never existed" still render identically once
more than one board is involved. The Feather did this on 2026-09-20.

Keep a board once seen and give it a greyed row reading `last seen 2.6 d ago` rather than
dropping it. That needs a last-known position from outside the window — a second query per
device, `pageSort=desc&pageLimit=1` with no start bound, only when the window came back empty —
so it costs one extra call per quiet board and nothing at all in the normal case. The device
buttons already come from `DEVICES`, so the remaining work is deciding what a board with no
points in range does to the time slider and the fit bounds.

---

## 4. Select `sram0_ns_app` explicitly on the Feather too  *(att: `app/boards/att_sram_partitions_feather.dtsi`)*

The Icarus needed `chosen { zephyr,sram = &sram0_ns_app; }` or the application linked over the
modem IPC shared memory and took a SecureFault on the first modem write (fixed in att commit
`f19e7fee`). The Feather's file has the same omission and is saved only by Circuit Dojo's board
dts happening to choose `sram0_ns_app` already.

Nothing is broken today. It is one line that makes the layout say what it means instead of
depending on a board file neither of these dtsi files controls.

---

## 5. Housekeeping  *(this repo)*

- `monitor.ps1` has its default port changed from COM15 to COM8 and is uncommitted. Decide
  whether the default should be the Icarus, or whether the script should take the board name and
  look the port up.
- `apps/accelerometer/` is untracked on purpose (decided 2026-09-16). Leave it that way unless
  asked.

---

**Before pushing anything from this repo:** `Get-TrackerHistory.ps1` carries both boards' IMEIs
as runtime defaults in its param block, not as comments, so a placeholder would silently break
`Serve-TrackerMap.ps1 -Watch`. Move them into the gitignored `secrets\nrfcloud.json` — which the
script already reads for the API key — rather than blanking them.
