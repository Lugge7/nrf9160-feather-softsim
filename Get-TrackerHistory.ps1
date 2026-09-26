<#
Pulls each device's stored positions out of nRF Cloud and writes them as one flat JSON
array for New-TrackerMap.ps1, plus their battery readings as a second one. Every record
carries a `device` field naming which board it came from.

    .\Get-TrackerHistory.ps1                       # every registered board, last 24 h
    .\Get-TrackerHistory.ps1 -Hours 168            # last week
    .\Get-TrackerHistory.ps1 -DeviceId nrf-<imei> -DeviceName Icarus   # one board
    .\Get-TrackerHistory.ps1 -Out track.json

With no -DeviceId, the boards come from secrets\boards.json, the registry that
New-IcarusBoard.ps1 appends to -- so a new board reaches the map without editing this file,
and no IMEI lives in tracked source:

    [ { "name": "Icarus", "deviceId": "nrf-<imei>", ... }, ... ]

-DeviceId and -DeviceName are parallel arrays. A device with no name given falls back to
its own id.

The API key is the *legacy* nRF Cloud key, not a Memfault Organization Auth Token -- an OAT
gets 401 here, the same way it does on nrf_cloud_onboard. Get it from nrfcloud.com -> User
Account, reached through the "Legacy App" link. Store it as secrets\nrfcloud.json:

    { "apiKey": "..." }

secrets\ is gitignored.

Why /v1/location/history rather than /v1/messages: the history endpoint records how each
position was obtained, which is the whole point of the map -- a GNSS fix and a cell-tower
estimate are different claims about where the device was, and averaging them on one map
would be misleading. /v1/messages carries the device's own GNSS uplinks but not the
positions nRF Cloud resolved on the device's behalf.

One device failing does not abort the run. A board that is asleep, unprovisioned, or
simply new has no history, and the map is still worth building from the other one.
#>
param(
    [string[]] $DeviceId   = @(),
    [string[]] $DeviceName = @(),
    [int]      $Hours      = 24,
    [string]   $Out        = 'track.json',
    [string]   $BatteryOut = 'battery.json',
    [string]   $KeyFile    = 'secrets\nrfcloud.json',
    [string]   $BoardsFile = 'secrets\boards.json'
)

$ErrorActionPreference = 'Stop'

if ($DeviceId.Count -eq 0) {
    if (-not (Test-Path $BoardsFile)) {
        throw "No -DeviceId given and no registry at $BoardsFile."
    }
    # Not wrapped in @(): ConvertFrom-Json already yields the array, and piping enumerates it.
    $registry   = Get-Content $BoardsFile -Raw | ConvertFrom-Json
    $DeviceId   = $registry | ForEach-Object { $_.deviceId }
    $DeviceName = $registry | ForEach-Object { $_.name }
}

if (-not (Test-Path $KeyFile)) {
    throw "No API key at $KeyFile. Create it with: { `"apiKey`": `"<legacy nRF Cloud key>`" }"
}
$apiKey = (Get-Content $KeyFile -Raw | ConvertFrom-Json).apiKey
if (-not $apiKey) { throw "$KeyFile has no apiKey field." }

$start = (Get-Date).ToUniversalTime().AddHours(-$Hours).ToString('yyyy-MM-ddTHH:mm:ssZ')
$end   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

$headers = @{ Authorization = "Bearer $apiKey" }

# Pair each id with a name. Zipping by index rather than requiring a hashtable keeps the
# command line short for the common case of passing one -DeviceId.
$devices = for ($i = 0; $i -lt $DeviceId.Count; $i++) {
    $nm = if ($i -lt $DeviceName.Count -and $DeviceName[$i]) { $DeviceName[$i] } else { $DeviceId[$i] }
    [pscustomobject]@{ Id = $DeviceId[$i]; Name = $nm }
}

# ---- paging --------------------------------------------------------------------------
# Both endpoints page the same way, so the loop lives in one place. The next-token field
# has been spelled both ways across API revisions; accept either rather than silently
# fetching only the first page.

function Get-NrfPaged {
    param([string] $Uri)

    $out = New-Object System.Collections.ArrayList
    $tok = $null

    do {
        $u = $Uri
        if ($tok) { $u += "&pageNextToken=$([uri]::EscapeDataString($tok))" }

        $resp = Invoke-RestMethod -Uri $u -Headers $headers -Method Get
        foreach ($it in @($resp.items)) { [void]$out.Add($it) }

        $tok = $resp.pageNextToken
        if (-not $tok) { $tok = $resp.nextPageToken }
    } while ($tok)

    return ,$out
}

function Get-NrfMessages {
    param([string] $Id, [string] $AppId)

    return Get-NrfPaged -Uri ('https://api.nrfcloud.com/v1/messages' +
        "?deviceId=$([uri]::EscapeDataString($Id))" +
        "&appId=$AppId&start=$start&end=$end&pageLimit=100&pageSort=asc")
}

# ---- positions -----------------------------------------------------------------------

$points = New-Object System.Collections.ArrayList

foreach ($dev in $devices) {
    try {
        $items = Get-NrfPaged -Uri ('https://api.nrfcloud.com/v1/location/history' +
            "?deviceId=$([uri]::EscapeDataString($dev.Id))" +
            "&start=$start&end=$end&pageLimit=100&pageSort=asc")
    } catch {
        Write-Warning "$($dev.Name): location pull failed: $($_.Exception.Message)"
        continue
    }

    if ($items.Count -eq 0) {
        Write-Warning "$($dev.Name): no positions in the last $Hours h. Widen -Hours, or check the device id."
    }

    # Normalise into the shape the map expects. Field names vary between the history
    # endpoint and the ground-fix response, so take the first spelling that is present
    # rather than assuming one; an unmapped field would otherwise surface as a point at 0,0.
    $n = 0
    foreach ($it in $items) {
        $lat = $it.lat;         if ($null -eq $lat) { $lat = $it.latitude }
        $lon = $it.lon;         if ($null -eq $lon) { $lon = $it.longitude }
        $acc = $it.uncertainty; if ($null -eq $acc) { $acc = $it.accuracy }
        $ts  = $it.insertedAt;  if ($null -eq $ts)  { $ts = $it.timestamp }
        $svc = $it.serviceType; if ($null -eq $svc) { $svc = $it.type }

        if ($null -eq $lat -or $null -eq $lon) { continue }

        [void]$points.Add([pscustomobject]@{
            ts       = [int][double]::Parse(((Get-Date $ts).ToUniversalTime() -
                         (Get-Date '1970-01-01T00:00:00Z').ToUniversalTime()).TotalSeconds)
            lat      = [double]$lat
            lon      = [double]$lon
            accuracy = if ($null -ne $acc) { [double]$acc } else { 0 }
            source   = "$svc".ToUpper()
            device   = $dev.Name
        })
        $n++
    }

    Write-Host ("{0}: {1} positions" -f $dev.Name, $n)
}

# Sorted across devices, not within one. The time slider and the per-device track lines
# both walk this array in order, and interleaving by timestamp is what makes a shared
# window mean the same thing for both boards.
$points = @($points | Sort-Object ts)

# ConvertTo-Json unwraps a one-element array, which would make POINTS an object in the
# page and break every .map() and .filter() on it.
$ptJson = ($points | Select-Object ts, lat, lon, accuracy, source, device | ConvertTo-Json -Depth 4)
if ($points.Count -eq 0) { $ptJson = '[]' }
if ($points.Count -eq 1) { $ptJson = "[$ptJson]" }

# Absolute -Out must not be joined against the working directory; see the same guard in
# New-TrackerMap.ps1 for what that silently breaks.
$outPath = if ([System.IO.Path]::IsPathRooted($Out)) {
    [System.IO.Path]::GetFullPath($Out)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Out))
}
[System.IO.File]::WriteAllText($outPath, $ptJson, (New-Object System.Text.UTF8Encoding($false)))

$byDev = $points | Group-Object device | ForEach-Object {
    $src = $_.Group | Group-Object source | ForEach-Object { "$($_.Name)=$($_.Count)" }
    "$($_.Name): $($src -join ' ')"
}
Write-Host ("wrote {0} points to {1}  [{2}]" -f $points.Count, $Out, ($byDev -join ' | ')) -ForegroundColor Cyan

# ---- battery -------------------------------------------------------------------------
# A second pull, against /v1/messages rather than /v1/location/history. The history
# endpoint only knows about positions; everything the device sends with
# nrf_cloud_coap_sensor_send() -- battery percentage and cell voltage -- arrives as a
# message and is invisible there.
#
# The two appIds are fetched separately because the API filters on one at a time, then
# paired on the device's own timestamp. They are sent from the same sample, one after the
# other, so message.ts is identical for the pair; receivedAt differs by a second or so and
# would not pair reliably.

$battery = New-Object System.Collections.ArrayList

foreach ($dev in $devices) {
    # A device that has never reported battery is not an error -- every build before this
    # one behaved that way, and the map must still come out.
    try {
        $pct  = Get-NrfMessages -Id $dev.Id -AppId 'BATTERY'
        $volt = Get-NrfMessages -Id $dev.Id -AppId 'VOLTAGE'
    } catch {
        Write-Warning "$($dev.Name): battery pull failed: $($_.Exception.Message). The map will build without it."
        continue
    }

    # Keyed by the device timestamp so the voltage lands on its own percentage. Voltage is
    # optional: an older firmware sent BATTERY alone, and those readings are still worth
    # plotting.
    $voltByTs = @{}
    foreach ($m in $volt) {
        if ($null -ne $m.message.ts) { $voltByTs[[string]$m.message.ts] = [double]$m.message.data }
    }

    $n = 0
    foreach ($m in $pct) {
        if ($null -eq $m) { continue }

        $ms = $m.message.ts
        if ($null -eq $ms) {
            # No device timestamp: fall back to when the cloud saw it. Off by the uplink
            # latency, which is seconds -- irrelevant at the scale this is plotted on.
            $ms = [int64](((Get-Date $m.receivedAt).ToUniversalTime() -
                   (Get-Date '1970-01-01T00:00:00Z').ToUniversalTime()).TotalMilliseconds)
        }

        $v = $voltByTs[[string]$ms]

        [void]$battery.Add([pscustomobject]@{
            ts      = [int][math]::Floor([double]$ms / 1000)
            pct     = [double]$m.message.data
            voltage = if ($null -ne $v) { [double]$v } else { 0 }
            device  = $dev.Name
        })
        $n++
    }

    Write-Host ("{0}: {1} battery readings" -f $dev.Name, $n)
}

$battery = @($battery | Sort-Object ts)

$batJson = ($battery | Select-Object ts, pct, voltage, device | ConvertTo-Json -Depth 3)
if ($battery.Count -eq 0)  { $batJson = '[]' }
if ($battery.Count -eq 1)  { $batJson = "[$batJson]" }

$batPath = if ([System.IO.Path]::IsPathRooted($BatteryOut)) {
    [System.IO.Path]::GetFullPath($BatteryOut)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $BatteryOut))
}
[System.IO.File]::WriteAllText($batPath, $batJson, (New-Object System.Text.UTF8Encoding($false)))

if ($battery.Count) {
    $latest = $battery | Group-Object device | ForEach-Object {
        $n = $_.Group[-1]
        "{0} {1}% / {2} V" -f $_.Name, $n.pct, [math]::Round($n.voltage, 3)
    }
    Write-Host ("wrote {0} battery readings to {1}  [{2}]" -f
        $battery.Count, $BatteryOut, ($latest -join ' | ')) -ForegroundColor Cyan
} else {
    Write-Host ("wrote 0 battery readings to {0}" -f $BatteryOut) -ForegroundColor DarkYellow
}
