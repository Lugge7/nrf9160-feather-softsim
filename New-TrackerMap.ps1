<#
Turns the JSON from Get-TrackerHistory.ps1 into a single self-contained map.html.

    .\tools\New-TrackerMap.ps1                          # track.json -> map.html
    .\tools\New-TrackerMap.ps1 -In week.json -Out week.html
    .\tools\New-TrackerMap.ps1 -Open                    # and open it

Points are embedded in the page rather than fetched, because the file is opened from disk
and fetch() against file:// is blocked. Leaflet itself comes from cdnjs, so the page needs
a network connection the first time.

GNSS fixes and cell-tower estimates are drawn as separate, separately toggleable layers.
They are not the same kind of claim: a GNSS fix measured 2.7-7.9 m here, while the
cell-tower estimate on this SIM came back with hundreds of metres of uncertainty. Drawing
both with one symbol makes the track look noisy when it is really two instruments of very
different precision.

Several boards share one page. Each point carries a `device` field from
Get-TrackerHistory.ps1, and the panel gains All / <board> buttons that scope the map, the
counts, the median accuracies and the battery rows to one board at a time. Boards are kept
apart rather than merged: each gets its own track line, because a line joining two devices
would draw a leg between places neither of them travelled, and the median accuracies are
per board because the two have different antennas. The device filter is a separate control
from the Leaflet layer list on purpose -- folding boards into that list would multiply its
rows by the number of boards, and it is already at the limit of what fits on a phone.

The JavaScript below uses string concatenation rather than template literals on purpose:
this file is a PowerShell here-string, where a backtick escapes the next character and
${...} expands a variable, so template literals would need escaping on every line and one
missed backtick would produce silently wrong output.
#>
param(
    [string] $In    = 'track.json',
    [string] $BatteryIn = 'battery.json',
    [string] $Out   = 'map.html',
    # Also the device name given to points in a track.json written before the map handled
    # more than one board, so it should name the fleet rather than describe it.
    [string] $Title = 'nRF9160 trackers',
    # How often the served page re-reads points.json. Only meaningful when the page is
    # served; opened from disk the poll is skipped entirely. Serve-TrackerMap.ps1 passes
    # its own -PollSeconds through, so the two stay in step.
    [int]    $PollSeconds = 20,
    [switch] $Open
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $In)) { throw "$In not found. Run Get-TrackerHistory.ps1 first." }

# Do NOT wrap this in @(). Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as
# a single pipeline object, so @(...) yields a one-element array whose only member is the
# real array -- every later Where-Object then sees one opaque Object[] and reports
# "Property accuracy cannot be found".
$points = Get-Content $In -Raw | ConvertFrom-Json
if ($points -isnot [array]) { $points = @($points) }
# An empty window is a state to render, not an error to raise. Throwing here froze the
# served page for 15.7 hours on 2026-09-22: the tracker went quiet, its last fix aged out
# of the 24 h window, Get-TrackerHistory wrote an empty track.json, and every rebuild after
# that died here. Serve-TrackerMap.ps1's watch job caught the exception, logged it 575
# times and kept serving the last good map.html -- a frozen page that looked entirely
# normal, with nothing on screen to say the data had stopped. A blank map that says so is
# worth more than a stale one that does not.
if ($points.Count -eq 0) {
    Write-Host "$In has no points in the window; building an empty map." -ForegroundColor DarkYellow
}

# Battery is optional and stays that way. -Battery can name a file that does not exist
# yet, and a track pulled before the firmware ever reported a cell voltage is still a
# perfectly good map -- it just has no battery row.
# The parameter is -BatteryIn, not -Battery, so that it cannot collide with $battery
# below. Variable names are case-insensitive here, and a [string] parameter keeps its type
# constraint for the rest of the script: every later assignment of the array is silently
# coerced back to a string, whose .Count is 1 and whose ts property is null. The page then
# shows one phantom reading with no timestamp and no voltage, and nothing reports an error.
$battery = @()
if (Test-Path $BatteryIn) {
    $battery = Get-Content $BatteryIn -Raw | ConvertFrom-Json
    if ($null -eq $battery) { $battery = @() }
    if ($battery -isnot [array]) { $battery = @($battery) }
    # A reading with no timestamp cannot be placed on the trace and would sort to the
    # front, taking the "latest" slot with it. Drop those rather than draw them.
    $battery = @($battery | Where-Object { $null -ne $_ -and $null -ne $_.ts })
}

# nRF Cloud reports the method as GNSS, or SCELL/MCELL for single- and multi-cell tower
# estimates. Anything else -- WIFI today, whatever is added later -- is kept and shown under
# its own name rather than dropped, so an unexpected source is visible instead of silently
# missing from the map.
foreach ($p in $points) {
    if (-not $p.source) {
        $p | Add-Member -NotePropertyName source -NotePropertyValue 'UNKNOWN' -Force
    }
    # A track.json written before the map knew about more than one board has no device
    # field. Fall back to the page title rather than inventing a name, so an old file
    # still renders as the single device it was.
    if (-not $p.device) {
        $p | Add-Member -NotePropertyName device -NotePropertyValue $Title -Force
    }
}

# Device order is first-seen, not alphabetical, so the colour each board gets is stable
# for as long as it keeps reporting -- sorting would reshuffle every legend the day a
# board with an earlier name is added.
$deviceNames = @()
foreach ($p in $points) {
    if ($deviceNames -notcontains $p.device) { $deviceNames += $p.device }
}
foreach ($b in $battery) {
    if (-not $b.device) { $b | Add-Member -NotePropertyName device -NotePropertyValue $Title -Force }
    if ($deviceNames -notcontains $b.device) { $deviceNames += $b.device }
}

$gnss  = @($points | Where-Object { $_.source -eq 'GNSS' })
$cell  = @($points | Where-Object { $_.source -like '*CELL*' })
$other = @($points | Where-Object { $_.source -ne 'GNSS' -and $_.source -notlike '*CELL*' })

function Get-Median {
    param([double[]] $Values)
    if ($Values.Count -eq 0) { return 0 }
    $s = @($Values | Sort-Object)
    if ($s.Count % 2) { return $s[[int](($s.Count - 1) / 2)] }
    return ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2
}

$gnssVals = @($gnss | Where-Object { $_.accuracy -gt 0 } | Select-Object -ExpandProperty accuracy)
$cellVals = @($cell | Where-Object { $_.accuracy -gt 0 } | Select-Object -ExpandProperty accuracy)
$gnssAcc = Get-Median -Values $gnssVals
$cellAcc = Get-Median -Values $cellVals

$epoch = [datetime]::SpecifyKind([datetime]'1970-01-01T00:00:00', 'Utc')
# Measure-Object over an empty set returns $null, and AddSeconds($null) throws. Both are
# only ever shown as label text, so an empty window gets a dash rather than a date.
if ($points.Count) {
    $first = $epoch.AddSeconds(($points | Measure-Object ts -Minimum).Minimum).ToLocalTime()
    $last  = $epoch.AddSeconds(($points | Measure-Object ts -Maximum).Maximum).ToLocalTime()
} else {
    $first = $null
    $last  = $null
}

# ConvertTo-Json unwraps a single-element array, which would make POINTS an object and
# break every .map() call in the page.
$json = ($points | Select-Object ts, lat, lon, accuracy, source, device | ConvertTo-Json -Depth 3 -Compress)
# ConvertTo-Json emits nothing at all for an empty set, which would render as
# "var POINTS = ;" and break the page outright -- worse than the freeze this replaced. The
# zero case only became reachable when the throw above was removed.
if ($points.Count -eq 0) { $json = '[]' }
if ($points.Count -eq 1) { $json = "[$json]" }

$batJson = ($battery | Select-Object ts, pct, voltage, device | ConvertTo-Json -Depth 3 -Compress)
if ($battery.Count -eq 0) { $batJson = '[]' }
if ($battery.Count -eq 1) { $batJson = "[$batJson]" }

# Names only. The page derives each board's colour from its index here, so that the map,
# the battery rows and the device buttons cannot disagree about which board is which.
$devJson = ($deviceNames | ConvertTo-Json -Depth 2 -Compress)
if ($deviceNames.Count -eq 0) { $devJson = '[]' }
if ($deviceNames.Count -eq 1) { $devJson = "[$devJson]" }

# The whole control is pointless with one board, and on a phone it would cost a row of
# screen for nothing. Emitted only when there is a choice to make.
$deviceHtml = ''
if ($deviceNames.Count -gt 1) {
    $btns = ($deviceNames | ForEach-Object {
        '<button type="button" class="dev-btn" data-dev="' + $_ + '">' + $_ + '</button>'
    }) -join ''
    $deviceHtml = '<div class="devs" id="devs">' +
                  '<button type="button" class="dev-btn on" data-dev="*">All</button>' +
                  $btns + '</div>'
}

$builtAt   = Get-Date -Format 'HH:mm:ss'
$gnssRound = [math]::Round($gnssAcc, 1)
$cellRound = [math]::Round($cellAcc, 0)
$firstTxt  = if ($first) { $first.ToString('yyyy-MM-dd HH:mm') } else { '--' }
$lastTxt   = if ($last)  { $last.ToString('yyyy-MM-dd HH:mm') }  else { '--' }

$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="mobile-web-app-capable" content="yes">
<title>$Title</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.min.css">
<style>
  :root {
    color-scheme: light dark;
    /* Notch and home-indicator insets. Zero on everything that is not a modern phone,
       so the same rules serve desktop without a second set of offsets. */
    --safe-t: env(safe-area-inset-top, 0px);
    --safe-b: env(safe-area-inset-bottom, 0px);
    --safe-l: env(safe-area-inset-left, 0px);
    --safe-r: env(safe-area-inset-right, 0px);
  }
  html, body { margin: 0; height: 100%; font: 14px/1.5 system-ui, -apple-system, Segoe UI, sans-serif; }
  /* Stops iOS Safari treating a drag that starts on a control as a page scroll or an
     overscroll bounce. The map does its own panning; nothing here should ever scroll. */
  body { overscroll-behavior: none; }
  #map { position: absolute; inset: 0; }
  .panel {
    position: absolute; z-index: 1000;
    top: calc(12px + var(--safe-t)); left: calc(12px + var(--safe-l));
    background: rgba(255,255,255,.94); color: #111;
    border-radius: 10px; padding: 12px 14px; min-width: 232px;
    box-shadow: 0 2px 14px rgba(0,0,0,.25);
    max-width: calc(100vw - 24px - var(--safe-l) - var(--safe-r));
  }
  @media (prefers-color-scheme: dark) { .panel { background: rgba(28,28,30,.94); color: #eee; } }
  .panel h1 { margin: 0; font-size: 15px; }
  /* <details> rather than a JS toggle: the open/closed state is native, keyboard
     accessible, and correct before any script runs. Open by default; the media query
     below closes it on a phone, where the panel would otherwise cover the map. */
  .panel > summary {
    cursor: pointer; list-style: none; display: flex;
    align-items: center; justify-content: space-between; gap: 10px;
  }
  .panel > summary::-webkit-details-marker { display: none; }
  .panel > summary::after {
    content: '\25BE'; opacity: .5; transition: transform .15s;
  }
  .panel[open] > summary::after { transform: rotate(180deg); }
  .panel > summary + * { margin-top: 8px; }
  .panel dl { margin: 0; display: grid; grid-template-columns: auto auto; gap: 2px 12px; }
  .panel dt { opacity: .65; }
  .panel dd { margin: 0; text-align: right; font-variant-numeric: tabular-nums; }
  /* Hiding an element whose CSS gives it a display value needs the !important; the
     battery row is display:flex and would otherwise ignore the attribute entirely. */
  [hidden] { display: none !important; }

  /* Battery. Drawn as a cell rather than written as a number, because state of charge is
     the one figure on this panel meant to be read at a glance. */
  .batt { margin-top: 10px; display: flex; align-items: center; gap: 9px; }
  .batt-cell {
    position: relative; box-sizing: border-box; flex: none;
    width: 34px; height: 16px; padding: 2px;
    border: 2px solid currentColor; border-radius: 3px; opacity: .85;
  }
  /* The terminal nub, so the shape reads as a battery at 34px wide. */
  .batt-cell::after {
    content: ''; position: absolute; right: -5px; top: 4px;
    width: 3px; height: 6px; background: currentColor; border-radius: 0 2px 2px 0;
  }
  .batt-fill { display: block; height: 100%; width: 0; border-radius: 1px;
               background: #3ba55d; transition: width .3s, background .3s; }
  .batt-num { font-variant-numeric: tabular-nums; }
  .batt-num b { font-size: 15px; }
  .batt-num span { opacity: .65; }
  .batt-age { margin-left: auto; font-size: 11px; opacity: .55; white-space: nowrap; }
  /* Board name on its own battery row. Fixed width so two bars line up under each other
     rather than starting at whatever the longer name happens to measure. */
  .batt-who { font-size: 11px; opacity: .7; width: 52px; flex: 0 0 52px;
              overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* Voltage trace. The percentage is a curve fitted over the voltage and sits pinned at
     100 for the first days of a charge, so the discharge is only actually visible here.
     overflow:visible keeps the two axis labels from being clipped at the edges. */
  .spark { margin-top: 8px; width: 100%; height: 34px; display: block; overflow: visible; }
  .spark path { fill: none; stroke: #4a6fa5; stroke-width: 1.5; }
  .spark .sp-area { fill: rgba(74,111,165,.16); stroke: none; }
  .spark text { font-size: 9px; fill: currentColor; opacity: .55; }

  .scale { margin-top: 10px; font-size: 12px; opacity: .75; }
  .bar { height: 6px; border-radius: 3px; margin: 4px 0 2px;
         background: linear-gradient(90deg, #4a6fa5, #f7b32b, #e23b3b); }
  .row { display: flex; justify-content: space-between; font-size: 11px; }
  /* Device filter. Laid out as a wrapping row so a third board pushes the buttons onto a
     second line instead of overflowing the panel. */
  /* Shown when the selected board has nothing in the window. Amber rather than red: an
     idle tracker is not a fault, and the panel's "Updated" clock right below it is what
     proves the page itself is still live. */
  .stale {
    margin: 2px 0 8px; padding: 7px 9px; border-radius: 7px; font-size: 12px;
    background: rgba(247,179,43,.16); border: 1px solid rgba(247,179,43,.5);
  }
  .devs { display: flex; flex-wrap: wrap; gap: 4px; margin: 2px 0 8px; }
  .dev-btn {
    font: 12px/1 system-ui, sans-serif; padding: 5px 9px; cursor: pointer;
    border: 1px solid rgba(0,0,0,.25); border-radius: 999px;
    background: rgba(0,0,0,.04); color: inherit;
  }
  .dev-btn.on { background: #2b6cb0; border-color: #2b6cb0; color: #fff; }
  /* The swatch ties a button to the track line drawn for that board. Set from JS, because
     the colours come from the same table the polylines use. */
  .dev-btn i { display: inline-block; width: 8px; height: 8px; border-radius: 50%;
               margin-right: 6px; vertical-align: 1px; background: currentColor; }

  .key { margin-top: 10px; font-size: 12px; display: grid; gap: 4px; }
  .key span { display: inline-flex; align-items: center; gap: 7px; }
  .key .devkey i { width: 14px; height: 3px; border-radius: 2px; }
  .dot { width: 11px; height: 11px; border-radius: 50%; background: #e23b3b;
         border: 2px solid #fff; box-shadow: 0 0 0 1px rgba(0,0,0,.3); }
  .sq { width: 10px; height: 10px; background: #6a8ea8; border: 2px solid #fff;
        transform: rotate(45deg); box-shadow: 0 0 0 1px rgba(0,0,0,.3); }
  .leaflet-popup-content { font: 13px/1.45 system-ui, sans-serif; }
  .leaflet-popup-content b { font-size: 14px; }
  .leaflet-popup-content code { font-size: 12px; opacity: .7; }
  .cell-icon { background: transparent; border: 0; }
  .cell-icon div { width: 10px; height: 10px; background: #6a8ea8; border: 2px solid #fff;
                   transform: rotate(45deg); box-shadow: 0 0 0 1px rgba(0,0,0,.3); }

  .timeline {
    position: absolute; z-index: 1000;
    left: calc(12px + var(--safe-l)); right: calc(12px + var(--safe-r));
    bottom: calc(12px + var(--safe-b));
    background: rgba(255,255,255,.94); color: #111;
    border-radius: 10px; padding: 10px 16px 14px;
    box-shadow: 0 2px 14px rgba(0,0,0,.25);
  }
  @media (prefers-color-scheme: dark) { .timeline { background: rgba(28,28,30,.94); color: #eee; } }
  .tl-labels { display: flex; justify-content: space-between; font-size: 12px;
               font-variant-numeric: tabular-nums; margin-bottom: 6px; }
  .tl-labels .mid { opacity: .65; }
  .tl-track { position: relative; height: 22px; }
  /* The selected span, drawn under both inputs. */
  .tl-rail { position: absolute; top: 9px; left: 0; right: 0; height: 4px;
             border-radius: 2px; background: rgba(128,128,128,.35); }
  .tl-sel { position: absolute; top: 9px; height: 4px; border-radius: 2px;
            background: linear-gradient(90deg, #4a6fa5, #f7b32b, #e23b3b); }
  /* Two inputs stacked on one rail. The track is transparent and ignores the pointer so
     whichever thumb is under the cursor gets the drag; without pointer-events:none on the
     input, the upper input would swallow every click on the lower thumb. */
  .tl-track input[type=range] {
    position: absolute; top: 0; left: 0; width: 100%; height: 22px; margin: 0;
    -webkit-appearance: none; appearance: none; background: none; pointer-events: none;
  }
  .tl-track input[type=range]::-webkit-slider-thumb {
    -webkit-appearance: none; pointer-events: auto;
    width: var(--thumb); height: var(--thumb); border-radius: 50%;
    background: #fff; border: 2px solid #555; cursor: grab;
    box-shadow: 0 1px 3px rgba(0,0,0,.4);
  }
  .tl-track input[type=range]::-moz-range-thumb {
    pointer-events: auto;
    width: var(--thumb); height: var(--thumb); border-radius: 50%;
    background: #fff; border: 2px solid #555; cursor: grab;
    box-shadow: 0 1px 3px rgba(0,0,0,.4);
  }
  .tl-track input[type=range]::-moz-range-track { background: none; }
  /* A drag starting on a thumb must move the thumb, not scroll or zoom the page.
     Without this iOS treats the first few pixels as a pan and the handle jumps. */
  .tl-track input[type=range] { touch-action: none; }
  :root { --thumb: 16px; }

  /* ---- phones ----------------------------------------------------------------
     Everything above is the desktop layout. The panel and the timeline together
     would cover most of a 390px screen, so on a narrow viewport the panel starts
     collapsed to its title bar and the touch targets grow to the ~28px that a
     fingertip actually needs. */
  @media (max-width: 700px), (pointer: coarse) {
    :root { --thumb: 28px; }
    .panel { min-width: 0; padding: 10px 12px; }
    .panel h1 { font-size: 14px; }
    .timeline { padding: 8px 12px 12px; }
    .tl-track { height: 32px; }
    .tl-rail, .tl-sel { top: 14px; }
    .tl-track input[type=range] { height: 32px; }
    .tl-labels { font-size: 11px; gap: 8px; }
    /* The middle count is the first thing to drop when three timestamps will not
       fit; the two endpoints are what the handles are actually setting. */
    .tl-labels .mid { display: none; }
    /* Leaflet's own controls are built for a mouse. */
    .leaflet-touch .leaflet-bar a { width: 34px; height: 34px; line-height: 34px; }
    .leaflet-control-layers-toggle { width: 40px; height: 40px; background-size: 24px 24px; }
    .leaflet-popup-content { font-size: 14px; }
  }

  @media (max-width: 700px) {
    .panel > summary + * { margin-top: 8px; }
  }
</style>
</head>
<body>
<div id="map"></div>
<details class="panel" id="panel" open>
  <summary><h1>$Title</h1></summary>
  $deviceHtml
  <div class="stale" id="staleBox" hidden></div>
  <dl>
    <dt>GNSS fixes</dt><dd id="pnGnss">$($gnss.Count)</dd>
    <dt>Cell estimates</dt><dd id="pnCell">$($cell.Count)</dd>
    <dt>Other</dt><dd id="pnOther">$($other.Count)</dd>
    <dt>GNSS median acc.</dt><dd id="pnGnssAcc">$gnssRound m</dd>
    <dt>Cell median acc.</dt><dd id="pnCellAcc">$cellRound m</dd>
    <dt>Updated</dt><dd id="pnBuilt">$builtAt</dd>
  </dl>
  <div id="battList" hidden></div>
  <svg class="spark" id="battSpark" hidden></svg>
  <div class="scale">
    <div class="bar"></div>
    <div class="row"><span id="pnFirst">$firstTxt</span><span id="pnLast">$lastTxt</span></div>
  </div>
  <div class="key">
    <span><i class="dot"></i> GNSS fix</span>
    <span><i class="sq"></i> cell-tower estimate</span>
  </div>
</details>
<div class="timeline">
  <div class="tl-labels">
    <span id="tlFrom"></span>
    <span class="mid" id="tlCount"></span>
    <span id="tlTo"></span>
  </div>
  <div class="tl-track">
    <div class="tl-rail"></div>
    <div class="tl-sel" id="tlSel"></div>
    <input type="range" id="tlLo">
    <input type="range" id="tlHi">
  </div>
</div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/leaflet/1.9.4/leaflet.js"></script>
<script>
var POINTS = $json;
var BATTERY = $batJson;
var DEVICES = $devJson;

// Track-line colour per board, by index in DEVICES. Deliberately not the marker colours:
// a marker's fill encodes *time* through the colour ramp, so reusing those here would
// make two different things share one visual channel. These only ever draw the line and
// the legend swatch.
var DEV_COLOURS = ['#2b6cb0', '#c2410c', '#6b21a8', '#047857', '#a16207'];
function devColour(name) {
  var i = DEVICES.indexOf(name);
  return DEV_COLOURS[(i < 0 ? 0 : i) % DEV_COLOURS.length];
}

// '*' means every board. Kept as the device name rather than an index so that a poll
// bringing in a board that was not in the original DEVICES cannot shift the selection
// onto a different one.
var DEV_SEL = '*';
function devPass(p) { return DEV_SEL === '*' || p.device === DEV_SEL; }

// One definition of "small", used for every layout decision below, so the JS and the
// CSS media queries agree about what a phone is.
var SMALL = window.matchMedia('(max-width: 700px), (pointer: coarse)').matches;

// The info panel and Leaflet's zoom buttons both want the top-left corner, and the panel
// wins because it has the higher z-index -- the zoom buttons end up underneath it on
// every screen size. Zoom is created separately on the right instead, where it stacks
// above the layers control.
var map = L.map('map', { zoomControl: false });
L.control.zoom({ position: 'topright' }).addTo(map);

// Collapse the stats panel on a phone. It is opened in the markup so that the content is
// visible with no JS at all; this closes it only where it would cover the map.
if (SMALL) { document.getElementById('panel').removeAttribute('open'); }

// CARTO was the default here until it started requiring an API key. It still answers with
// HTTP 200, so nothing looks wrong from a status check -- the tile it returns is simply
// stamped "API KEY REQUIRED" across the image. Removed rather than left as an option,
// because a base layer that renders a watermark is worse than not offering it.
//
// OSM's own tiles are the default now. The earlier trouble with them was the deprecated
// {s}.tile.openstreetmap.org subdomain sharding, which OSM blocks outright; the plain
// hostname below is the supported form. Tile load depends on zoom and viewport, not on how
// many points are plotted, so a few hundred markers do not affect it either way.
//
// Esri is the second opinion. Aerial imagery makes it obvious whether a fix landed on the
// road or inside the building next to it, which is the interesting question for a cell
// estimate; the street map is a fallback if OSM is ever slow.
var baseLayers = {
  'OpenStreetMap': L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, attribution: '&copy; OpenStreetMap contributors'
  }),
  'Satellite (Esri)': L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}', {
    maxZoom: 19, attribution: 'Imagery &copy; Esri'
  }),
  'Street (Esri)': L.tileLayer('https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}', {
    maxZoom: 19, attribution: '&copy; Esri'
  })
};
baseLayers['OpenStreetMap'].addTo(map);

// Oldest blue, newest red, so a track reads as a direction. Colour carries time and shape
// carries the source, so neither has to be inferred from the other.
function colorFor(i, n) {
  if (n < 2) { return '#e23b3b'; }
  var t = i / (n - 1);
  var stops = [[74,111,165], [247,179,43], [226,59,59]];
  var seg = t < 0.5 ? 0 : 1;
  var f = t < 0.5 ? t * 2 : (t - 0.5) * 2;
  var a = stops[seg], b = stops[seg + 1];
  var r = Math.round(a[0] + (b[0] - a[0]) * f);
  var g = Math.round(a[1] + (b[1] - a[1]) * f);
  var bl = Math.round(a[2] + (b[2] - a[2]) * f);
  return 'rgb(' + r + ',' + g + ',' + bl + ')';
}

function fmt(ts) { return new Date(ts * 1000).toLocaleString(); }

// toLocaleString() on a phone gives something like "14/09/2026, 05:41:34" -- three of
// those will not fit across a 390px screen, and the seconds are noise at this scale.
// Popups keep the full form; only the two slider labels use this.
function fmtShort(ts) {
  var d = new Date(ts * 1000);
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) + ' ' +
         d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}
var fmtLabel = SMALL ? fmtShort : fmt;
function isCell(p) { return /CELL/.test(p.source || ''); }
function isOther(p) { return !isCell(p) && p.source !== 'GNSS'; }

var gnssLayer  = L.layerGroup();
var cellLayer  = L.layerGroup();
var otherLayer = L.layerGroup();
var trackLayer = L.layerGroup();

// One line through every point in time order, in its own layer. Hiding a point layer must
// not silently reshape the track -- a line that reroutes when you untick "Cell tower"
// would imply the device went somewhere it did not. Its coordinates are set by render().
// One line per board. Joining every board's fixes into a single polyline would draw a leg
// between two devices that were never in the same place, which is the one thing a track
// line must not imply. Created on demand so a board that first appears in a poll still
// gets a line without rebuilding the map.
var tracks = {};
function trackFor(name) {
  if (!tracks[name]) {
    tracks[name] = L.polyline([], {
      color: devColour(name), weight: 2, opacity: 0.55, dashArray: '4 4'
    }).addTo(trackLayer);
  }
  return tracks[name];
}

// Build every marker once and move it in and out of its layer as the time window changes.
// Rebuilding markers on each slider step would rebind popups and drop an open one mid-drag.
// This does run again when a poll brings in new fixes -- a new point set is a different
// map, and the colour ramp depends on each point's position in the whole series.
var entries = [];
function buildEntries() {
entries = POINTS.map(function (p, i) {
  var color = colorFor(i, POINTS.length);
  var cell = isCell(p);
  var other = isOther(p);
  var layer = cell ? cellLayer : (other ? otherLayer : gnssLayer);

  // Cell uncertainty runs to hundreds of metres, so its circle is dashed and very faint.
  // At that radius a solid fill would bury the GNSS track underneath it.
  var circle = null;
  if (p.accuracy > 0) {
    circle = L.circle([p.lat, p.lon], {
      radius: p.accuracy,
      color: cell ? '#6a8ea8' : color,
      weight: 1,
      opacity: cell ? 0.5 : 0.35,
      dashArray: cell ? '3 4' : null,
      fillColor: cell ? '#6a8ea8' : color,
      fillOpacity: cell ? 0.04 : 0.08
    });
  }

  var popup = '<b>' + fmt(p.ts) + '</b><br>' +
              // Named only when there is more than one board, so a single-device map
              // does not gain a line that says the same thing as its title.
              (DEVICES.length > 1
                 ? '<b style="color:' + devColour(p.device) + '">' + p.device + '</b><br>'
                 : '') +
              '<code>' + (p.source || 'UNKNOWN') + '</code><br>' +
              'derived from ' + (cell ? 'cell towers' : 'satellites') + '<br>' +
              p.lat.toFixed(6) + ', ' + p.lon.toFixed(6) + '<br>' +
              (p.accuracy ? 'accuracy ~' + Math.round(p.accuracy) + ' m'
                          : 'no accuracy reported');

  var marker;
  if (cell) {
    marker = L.marker([p.lat, p.lon], {
      icon: L.divIcon({ className: 'cell-icon', html: '<div></div>', iconSize: [10, 10] })
    });
  } else {
    marker = L.circleMarker([p.lat, p.lon], {
      radius: other ? 5 : 6,
      color: '#fff', weight: 2,
      fillColor: other ? '#8a8a8a' : color,
      fillOpacity: 0.95
    });
  }
  marker.bindPopup(popup);

  return { p: p, layer: layer, marker: marker, circle: circle };
});
}

trackLayer.addTo(map);
gnssLayer.addTo(map);
cellLayer.addTo(map);
otherLayer.addTo(map);

// No counts in these labels. They would be written once and then be wrong after the first
// poll, and the panel carries the same numbers and is kept up to date. "Other" is listed
// unconditionally for the same reason: a source that has never appeared yet may appear
// while the page is open.
var overlays = {};
overlays['GNSS'] = gnssLayer;
overlays['Cell tower'] = cellLayer;
overlays['Other'] = otherLayer;
overlays['Track line'] = trackLayer;
// Expanded on a desktop, where the list is a useful legend and there is room for it.
// Collapsed to a single button on a phone, where seven always-visible rows would cover
// the whole right-hand side of the map.
L.control.layers(baseLayers, overlays, { collapsed: SMALL }).addTo(map);

// ---- time window -----------------------------------------------------------------
// The two handles are timestamps, not indices, so the slider is linear in time: a long
// idle gap reads as a long gap. Index-based handles would space a 10-minute sample and a
// 12-hour sleep identically and hide exactly the pattern worth seeing.

var TS_MIN = 0;
var TS_MAX = 0;

var elLo = document.getElementById('tlLo');
var elHi = document.getElementById('tlHi');
var elSel = document.getElementById('tlSel');

[elLo, elHi].forEach(function (el) { el.step = 1; });

function render() {
  var lo = Math.min(+elLo.value, +elHi.value);
  var hi = Math.max(+elLo.value, +elHi.value);

  gnssLayer.clearLayers();
  cellLayer.clearLayers();
  otherLayer.clearLayers();

  var byDev = {};
  var shown = 0;
  entries.forEach(function (e) {
    if (e.p.ts < lo || e.p.ts > hi) { return; }
    if (!devPass(e.p)) { return; }
    if (e.circle) { e.circle.addTo(e.layer); }
    e.marker.addTo(e.layer);
    if (!byDev[e.p.device]) { byDev[e.p.device] = []; }
    byDev[e.p.device].push([e.p.lat, e.p.lon]);
    shown++;
  });

  // Every known line is reset, not just the ones with points in this window: a board
  // filtered out or scrolled past must lose its line rather than keep the last one it
  // had.
  Object.keys(tracks).forEach(function (name) { tracks[name].setLatLngs([]); });
  Object.keys(byDev).forEach(function (name) { trackFor(name).setLatLngs(byDev[name]); });

  var span = TS_MAX - TS_MIN;
  var a = span ? (lo - TS_MIN) / span : 0;
  var b = span ? (hi - TS_MIN) / span : 1;
  elSel.style.left = (a * 100) + '%';
  elSel.style.width = ((b - a) * 100) + '%';

  document.getElementById('tlFrom').textContent = fmtLabel(lo);
  document.getElementById('tlTo').textContent = fmtLabel(hi);
  // Counted against the points the device filter admits, not the whole file. "12 of 267"
  // while looking at one board would be comparing against the other board's points too.
  var total = POINTS.filter(devPass).length;
  document.getElementById('tlCount').textContent =
    shown + ' of ' + total + ' points';
}

elLo.addEventListener('input', render);
elHi.addEventListener('input', render);

// ---- panel ------------------------------------------------------------------------

function median(a) {
  if (!a.length) { return 0; }
  var s = a.slice().sort(function (x, y) { return x - y; });
  var m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function accOf(list) {
  return list.filter(function (p) { return p.accuracy > 0; })
             .map(function (p) { return p.accuracy; });
}

function pad(n) { return (n < 10 ? '0' : '') + n; }

function fmtStamp(ts) {
  var d = new Date(ts * 1000);
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) +
         ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes());
}

function setText(id, v) { document.getElementById(id).textContent = v; }

function updatePanel() {
  // Scoped to the selected board. The median accuracies especially: the two boards have
  // different antennas, and averaging them into one figure would describe neither.
  var sel = POINTS.filter(devPass);
  var g = sel.filter(function (p) { return p.source === 'GNSS'; });
  var c = sel.filter(isCell);
  var o = sel.filter(isOther);

  setText('pnGnss', g.length);
  setText('pnCell', c.length);
  setText('pnOther', o.length);
  setText('pnGnssAcc', median(accOf(g)).toFixed(1) + ' m');
  setText('pnCellAcc', Math.round(median(accOf(c))) + ' m');
  // The time the page last took in new data, which is the number that matters on a
  // served copy -- the build time would freeze at first load and quietly mislead.
  setText('pnBuilt', new Date().toLocaleTimeString());
  setText('pnFirst', sel.length ? fmtStamp(TS_MIN) : '--');
  setText('pnLast', sel.length ? fmtStamp(TS_MAX) : '--');

  // Says which of the two silences this is. Without it an empty map is indistinguishable
  // from a page that stopped refreshing -- the failure that froze this map for 15.7 h on
  // 2026-09-22 and looked completely normal while it did.
  var stale = document.getElementById('staleBox');
  if (sel.length) {
    stale.hidden = true;
  } else {
    stale.hidden = false;
    stale.textContent = (DEV_SEL === '*')
      ? 'No fixes in the window from any board. The page is still updating -- see the clock below.'
      : 'No fixes in the window from ' + DEV_SEL + '. The page is still updating -- see the clock below.';
  }
}

// ---- battery -----------------------------------------------------------------------

function fmtAge(ts) {
  var s = Math.max(0, Math.round(Date.now() / 1000 - ts));
  if (s < 90) { return s + ' s ago'; }
  var m = Math.round(s / 60);
  if (m < 90) { return m + ' min ago'; }
  var h = Math.round(m / 60);
  if (h < 48) { return h + ' h ago'; }
  return Math.round(h / 24) + ' d ago';
}

// The thresholds are where the firmware's discharge curve bends, so the colour and the
// device agree about what a low battery is rather than each having its own opinion.
function battColour(pct) {
  if (pct >= 40) { return '#3ba55d'; }
  if (pct >= 15) { return '#f7b32b'; }
  return '#e23b3b';
}

function drawSpark(list) {
  var svg = document.getElementById('battSpark');
  var pts = list.filter(function (b) { return b.voltage > 0; });

  // One reading is a dot, not a trend. Hide the trace until there is something to join.
  if (pts.length < 2) { svg.hidden = true; return; }
  svg.hidden = false;

  // Zero width means the panel is collapsed, which it is by default on a phone. Bail and
  // let the toggle handler below draw it when it is actually on screen -- drawing into a
  // zero-width box would put every point on top of the first one.
  var w = Math.round(svg.getBoundingClientRect().width);
  if (w < 20) { return; }

  var h = 34, padT = 9, padB = 10;

  var vs = pts.map(function (b) { return b.voltage; });
  var lo = Math.min.apply(null, vs);
  var hi = Math.max.apply(null, vs);

  // A resting battery moves by a couple of millivolts between samples. Auto-scaling that
  // would fill the box with a sawtooth of ADC noise and look like a failing cell, so hold
  // the axis open to at least 50 mV.
  if (hi - lo < 0.05) {
    var mid = (hi + lo) / 2;
    lo = mid - 0.025;
    hi = mid + 0.025;
  }

  var t0 = pts[0].ts;
  var span = (pts[pts.length - 1].ts - t0) || 1;

  function sx(b) { return (b.ts - t0) / span * w; }
  function sy(b) { return padT + (1 - (b.voltage - lo) / (hi - lo)) * (h - padT - padB); }

  var d = pts.map(function (b, i) {
    return (i ? 'L' : 'M') + sx(b).toFixed(1) + ' ' + sy(b).toFixed(1);
  }).join(' ');

  svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
  svg.innerHTML =
    '<path class="sp-area" d="' + d + ' L' + w + ' ' + h + ' L0 ' + h + ' Z"/>' +
    '<path d="' + d + '"/>' +
    '<text x="0" y="8">' + hi.toFixed(2) + ' V</text>' +
    '<text x="0" y="' + (h - 1) + '">' + lo.toFixed(2) + ' V</text>';
}

// Charge from cell voltage, rather than from the percentage the device reports.
//
// The firmware derives its own figure with a three-point curve (APP_POWER_CURVE_*_MV), and
// on a board whose divider the SAADC cannot settle against it comes out stuck or wrong.
// Voltage is the measurement; the percentage is an interpretation, so interpret it here
// where it can be changed without reflashing.
//
// Piecewise-linear over a standard single-cell LiPo discharge curve. The shape is the whole
// point: a LiPo spends most of its life between 3.9 and 3.6 V and then falls off a cliff, so
// a straight line from 4.2 to 3.0 would read far too high for most of the discharge. This is
// an estimate and is not meant to be better than a few percent -- under load the terminal
// voltage sags and recovers at rest, so the same cell reads differently depending on what
// the modem is doing.
var LIPO_CURVE = [
  [4.20, 100], [4.10, 94], [4.00, 85], [3.90, 76], [3.80, 62],
  [3.70, 44], [3.60, 25], [3.50, 12], [3.40, 6], [3.30, 3], [3.00, 0]
];

function pctFromVoltage(v) {
  if (typeof v !== 'number' || !(v > 0)) { return null; }

  var last = LIPO_CURVE.length - 1;
  if (v >= LIPO_CURVE[0][0])    { return 100; }
  if (v <= LIPO_CURVE[last][0]) { return 0; }

  for (var i = 0; i < last; i++) {
    var hiV = LIPO_CURVE[i][0],     hiP = LIPO_CURVE[i][1];
    var loV = LIPO_CURVE[i + 1][0], loP = LIPO_CURVE[i + 1][1];
    if (v <= hiV && v > loV) {
      return loP + (v - loV) / (hiV - loV) * (hiP - loP);
    }
  }
  return 0;
}

function applyBattery(list) {
  // Sorted here rather than trusted from the file: the page also takes this array from a
  // poll, and an out-of-order last element would report the wrong charge.
  BATTERY = (list || [])
    // Defensive: this array also arrives straight off the network, and one entry with a
    // null timestamp would sort to the front and be reported as the current charge.
    .filter(function (b) { return b && typeof b.ts === 'number'; })
    // Recompute the percentage from voltage, keeping the device's own figure only as a
    // fallback for older readings that carry no voltage (Get-TrackerHistory.ps1 writes
    // voltage = 0 for those, since an early firmware sent BATTERY without VOLTAGE).
    .map(function (b) {
      var v = (typeof b.voltage === 'number') ? b.voltage : 0;
      var derived = pctFromVoltage(v);
      return {
        ts: b.ts,
        voltage: v,
        device: b.device || (DEVICES.length ? DEVICES[0] : ''),
        pct: (derived !== null) ? derived
                                : (typeof b.pct === 'number' ? b.pct : null)
      };
    })
    // Drop anything left with no usable charge at all, which the bar and the colour
    // thresholds below would otherwise render as NaN.
    .filter(function (b) { return typeof b.pct === 'number'; })
    .sort(function (a, b) { return a.ts - b.ts; });

  var list = document.getElementById('battList');
  var mine = BATTERY.filter(devPass);

  if (!mine.length) {
    list.hidden = true;
    list.textContent = '';
    document.getElementById('battSpark').hidden = true;
    return;
  }

  // One row per board still reporting, newest reading per board. Two trackers on one
  // charge cycle is exactly the comparison this panel is for, so both stay on screen
  // under "All" rather than the panel showing whichever happened to report last.
  var order = [];
  var latest = {};
  mine.forEach(function (b) {
    if (!latest[b.device]) { order.push(b.device); }
    latest[b.device] = b;   // BATTERY is sorted ascending, so the last write wins
  });

  list.hidden = false;
  list.textContent = '';

  order.forEach(function (name) {
    var b = latest[name];
    var row = document.createElement('div');
    row.className = 'batt';

    if (DEVICES.length > 1) {
      var who = document.createElement('div');
      who.className = 'batt-who';
      who.textContent = name;
      who.style.color = devColour(name);
      row.appendChild(who);
    }

    var cell = document.createElement('div');
    cell.className = 'batt-cell';
    var fill = document.createElement('i');
    fill.className = 'batt-fill';
    fill.style.width = Math.max(0, Math.min(100, b.pct)) + '%';
    fill.style.background = battColour(b.pct);
    cell.appendChild(fill);
    row.appendChild(cell);

    var num = document.createElement('div');
    num.className = 'batt-num';
    var strong = document.createElement('b');
    strong.textContent = b.pct.toFixed(0) + '%';
    num.appendChild(strong);
    if (b.voltage > 0) {
      var v = document.createElement('span');
      v.textContent = ' ' + b.voltage.toFixed(2) + ' V';
      num.appendChild(v);
    }
    row.appendChild(num);

    // How old the reading is, not when it was taken: a tracker asleep on its heartbeat
    // reports hourly, and "4 h ago" is the part worth noticing.
    var age = document.createElement('div');
    age.className = 'batt-age';
    age.textContent = fmtAge(b.ts);
    row.appendChild(age);

    list.appendChild(row);
  });

  // The sparkline is a single trace, so it follows one board: the selected one, or the
  // first that has readings when every board is shown. Overlaying two discharge curves
  // in a 34-pixel box would be unreadable.
  var sparkDev = (DEV_SEL !== '*') ? DEV_SEL : order[0];
  drawSpark(mine.filter(function (b) { return b.device === sparkDev; }));
}

// The trace cannot be measured while the panel is shut, so redraw when it opens. Same for
// a resize, where the SVG box changes width but its viewBox does not follow on its own.
document.getElementById('panel').addEventListener('toggle', function () {
  // Via applyBattery so the trace belongs to the selected board. drawSpark(BATTERY) would
  // interleave both boards' voltages into one line the moment the panel was expanded.
  applyBattery(BATTERY);
});

// ---- taking in a new point set -----------------------------------------------------

function applyPoints(pts, isFirst) {
  // Whether the handles were spanning everything decides what happens to them. Left at
  // full range they should follow the data and reveal the new fixes; deliberately
  // narrowed to look at one stretch, they must stay where they are -- having the window
  // jump every minute while you are reading it would make the page unusable.
  var wasFull = true;
  var prevLo = 0, prevHi = 0;
  if (!isFirst) {
    prevLo = Math.min(+elLo.value, +elHi.value);
    prevHi = Math.max(+elLo.value, +elHi.value);
    wasFull = (prevLo <= TS_MIN && prevHi >= TS_MAX);
  }

  POINTS = pts;

  // A poll can introduce a board that was not in the build-time DEVICES list. Append it
  // so it gets a colour and a track line of its own. Its button only appears on the next
  // reload, which is the lesser problem: an unnamed board still being drawn beats one
  // silently sharing another board's line.
  POINTS.forEach(function (p) {
    if (p.device && DEVICES.indexOf(p.device) < 0) { DEVICES.push(p.device); }
  });

  buildEntries();

  // Math.min.apply(null, []) is Infinity, which would set the slider bounds to a range no
  // timestamp can fall inside and leave the page looking broken rather than empty.
  var ts = POINTS.map(function (p) { return p.ts; });
  if (ts.length) {
    TS_MIN = Math.min.apply(null, ts);
    TS_MAX = Math.max.apply(null, ts);
  } else {
    TS_MIN = TS_MAX = Math.floor(Date.now() / 1000);
  }

  elLo.min = elHi.min = TS_MIN;
  elLo.max = elHi.max = TS_MAX;

  if (wasFull) {
    elLo.value = TS_MIN;
    elHi.value = TS_MAX;
  } else {
    elLo.value = Math.max(TS_MIN, Math.min(TS_MAX, prevLo));
    elHi.value = Math.max(TS_MIN, Math.min(TS_MAX, prevHi));
  }

  updatePanel();
  render();
}

applyPoints(POINTS, true);
applyBattery(BATTERY);

// ---- device filter -----------------------------------------------------------------
// Present only when the pull covered more than one board; New-TrackerMap.ps1 emits no
// control for a single-device map, so every path here is guarded on the element existing.

var FIT_PAD = SMALL ? [30, 80] : [60, 90];

function selectDevice(name) {
  DEV_SEL = name;

  var box = document.getElementById('devs');
  if (box) {
    Array.prototype.forEach.call(box.querySelectorAll('.dev-btn'), function (b) {
      b.className = 'dev-btn' + (b.getAttribute('data-dev') === name ? ' on' : '');
    });
  }

  updatePanel();
  render();
  applyBattery(BATTERY);

  // Frame what is now on screen. Picking a board means wanting to look at it, and leaving
  // the view sitting over the other one's corner of the map would hide the answer.
  var pts = POINTS.filter(devPass);
  if (pts.length) {
    map.fitBounds(pts.map(function (p) { return [p.lat, p.lon]; }),
                  { padding: FIT_PAD, maxZoom: 17 });
  }
}

var devBox = document.getElementById('devs');
if (devBox) {
  // Swatch each button in its own track colour, so the control and the lines on the map
  // agree without a separate legend to keep in step.
  Array.prototype.forEach.call(devBox.querySelectorAll('.dev-btn'), function (b) {
    var d = b.getAttribute('data-dev');
    if (d === '*') { return; }
    var sw = document.createElement('i');
    sw.style.background = devColour(d);
    b.insertBefore(sw, b.firstChild);
  });

  // Delegated, because the click often lands on the swatch rather than the button.
  devBox.addEventListener('click', function (ev) {
    var b = ev.target && ev.target.closest ? ev.target.closest('.dev-btn') : null;
    if (b) { selectDevice(b.getAttribute('data-dev')); }
  });
}

// Fit once, to everything. Refitting on each slider step would yank the view around while
// the point of narrowing the window is usually to look closely at one place.
// Padding keeps the outermost points out from under the overlays. The timeline is a
// fixed strip along the bottom on every screen; the stats panel is only tall when it is
// expanded, which on a phone it is not.
// fitBounds on an empty list throws, so an empty window falls back to a wide view instead.
// The coordinates do not matter much -- there is nothing to look at -- but the map must
// still come up, because the panel on top of it is what explains why it is empty.
if (POINTS.length) {
  map.fitBounds(POINTS.map(function (p) { return [p.lat, p.lon]; }),
                { padding: SMALL ? [30, 80] : [60, 90], maxZoom: 17 });
} else {
  map.setView([59.33, 17.99], 9);
}

// A phone rotated between portrait and landscape leaves Leaflet with the old pixel size
// until it is told otherwise, which shows as grey bands where tiles were never fetched.
window.addEventListener('resize', function () {
  map.invalidateSize();
  // Through applyBattery rather than drawSpark directly, so the trace stays on whichever
  // board is selected instead of reverting to every reading from both.
  applyBattery(BATTERY);
});
window.addEventListener('orientationchange', function () {
  setTimeout(function () { map.invalidateSize(); }, 200);
});

// ---- live updates ------------------------------------------------------------------
// Only when the page is served. Opened straight off disk the protocol is file:, where
// fetch() is blocked and there is no server rebuilding points.json anyway, so the
// embedded POINTS above is all there is and polling would only log errors.

if (location.protocol === 'http:' || location.protocol === 'https:') {
  // Set by -PollSeconds, and passed through by Serve-TrackerMap.ps1 so the page and the
  // server cannot disagree about the rate. This only reads points.json off the server's
  // disk -- the expensive nRF Cloud pull is the server's -Watch, on its own schedule --
  // so a fast tick costs one small local request and nothing upstream. A tick that finds
  // the same data returns before touching the DOM, which is what keeps it cheap enough to
  // leave the page open on a phone.
  var POLL_MS = $($PollSeconds * 1000);
  var lastSig = POINTS.length + ':' + TS_MAX;

  function poll() {
    // Cache-busting query rather than trusting headers: the server sends no-store, but a
    // phone browser waking from sleep has its own ideas about revalidation.
    fetch('points.json?t=' + Date.now(), { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (pts) {
        if (!pts || !pts.length) { return; }

        // Compare before rebuilding. Most polls change nothing, and rebuilding every
        // marker each tick would close an open popup and drop a drag in progress.
        var max = Math.max.apply(null, pts.map(function (p) { return p.ts; }));
        var sig = pts.length + ':' + max;
        if (sig === lastSig) { return; }

        lastSig = sig;
        applyPoints(pts, false);
      })
      .catch(function () { /* server restarting, or asleep; try again next tick */ });
  }

  // Battery is a separate file and a separate fetch. Keeping it apart from the points
  // means a battery pull that failed in Get-TrackerHistory.ps1 costs the page nothing,
  // and it is re-applied unconditionally so the "x min ago" label keeps counting up even
  // on the many polls where the device has sent nothing new.
  function pollBattery() {
    fetch('battery.json?t=' + Date.now(), { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (b) { if (b) { applyBattery(b); } })
      .catch(function () { /* same as above: try again next tick */ });
  }

  setInterval(poll, POLL_MS);
  setInterval(pollBattery, POLL_MS);

  // A phone blanks the screen and suspends timers. Coming back to a stale map is the
  // most likely way to see old data, so refresh on focus as well as on the timer.
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { poll(); pollBattery(); }
  });
}
</script>
</body>
</html>
"@

# Not Out-File -Encoding utf8: Windows PowerShell 5.1 writes a BOM, which lands ahead of
# <!doctype html> and makes some browsers fall back to quirks mode. WriteAllText with an
# explicit UTF8Encoding($false) writes the same bytes a hand-written page has.
# Join-Path against the working directory only when -Out is relative. Joining an already
# absolute path yields "C:\here\C:\there\map.html", and GetFullPath then throws "The given
# path's format is not supported" -- which is how the watch loop in Serve-TrackerMap.ps1
# silently stopped rebuilding the page while still refreshing track.json.
$full = if ([System.IO.Path]::IsPathRooted($Out)) {
    [System.IO.Path]::GetFullPath($Out)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Out))
}
[System.IO.File]::WriteAllText($full, $html, (New-Object System.Text.UTF8Encoding($false)))

# The same array, written beside the page so a served copy can poll it and pick up new
# fixes without a reload. The page still embeds POINTS as well, so opening map.html
# straight off disk keeps working -- fetch() against file:// is blocked, and the poll is
# skipped there.
#
# Written to a temp name and moved into place: the poll can land mid-write, and a
# half-written file parses as invalid JSON. Move-Item over an existing file on the same
# NTFS volume swaps the directory entry rather than rewriting the contents.
$pointsPath = Join-Path ([System.IO.Path]::GetDirectoryName($full)) 'points.json'
$tmpPath = "$pointsPath.tmp"
[System.IO.File]::WriteAllText($tmpPath, $json, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tmpPath -Destination $pointsPath -Force
# Beside the page for the same reason as points.json, and written the same way -- the
# poll can land mid-write, and a half-written file is invalid JSON. Always written, even
# empty, so a page served from a directory that once had battery data does not keep
# fetching a stale copy after the file stops being produced.
$batPath = Join-Path ([System.IO.Path]::GetDirectoryName($full)) 'battery.json'

# Unless that is the file it was just read from. Building into the same directory the
# battery data lives in -- which -Out map.html in the repo root does -- would have the
# script overwrite its own input, and any hiccup in one build would then be baked in
# permanently instead of being corrected by the next pull.
$batSrc = if (Test-Path $BatteryIn) {
    (Resolve-Path -LiteralPath $BatteryIn).ProviderPath
} else { '' }

if ($batSrc -and $batSrc -eq $batPath) {
    Write-Host "battery.json is the input here; left as it is" -ForegroundColor DarkGray
} else {
    $batTmp = "$batPath.tmp"
    [System.IO.File]::WriteAllText($batTmp, $batJson, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $batTmp -Destination $batPath -Force
}

Write-Host ("wrote {0}  [{1} GNSS, {2} cell, {3} other, {4} battery]" -f $full, $gnss.Count, $cell.Count, $other.Count, $battery.Count) -ForegroundColor Cyan
if ($Open) { Start-Process $full }
