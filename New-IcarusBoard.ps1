<#
Takes a factory-fresh Actinius Icarus v2 from the box to the tracker map in one run.

    .\New-IcarusBoard.ps1 -Name 'Icarus 3'
    .\New-IcarusBoard.ps1 -Name 'Icarus 3' -Iccid <20-digit ICCID>  # pick the SIM
    .\New-IcarusBoard.ps1 -Name 'Icarus 3' -SkipModemUpdate -SkipCloud   # resume after a failure

Needs: the J-Link on the new board's SWD header, the board's USB plugged in, and a Monogoto
fulfilment CSV (columns ICCID..Profile) in the repo root. Takes ~15 min for the first board
(the tracker build is a full one) and ~5 min after that.

What it does, in order:

  1. Preflight   refuses a board that already runs the tracker or already holds a SoftSIM
  2. SIM         takes the first CSV SIM not already in secrets\boards.json
  3. Build       starts the tracker build in the background; steps 4-5 run meanwhile
  4. Modem       updates to mfw 1.3.7 -- the factory 1.2.3 has no AT%CSUS, so no SoftSIM
  5. Cloud       flashes apps/at_client, reads the IMEI, installs credentials, onboards
  6. Flash       tracker merged.hex (ERASE_ALL) plus the SoftSIM template at 0xF0000
  7. Verify      waits for "Connected to Cloud" with the new IMEI on the console
  8. Register    appends the board to secrets\boards.json, which the map reads

Why onboarding happens on apps/at_client and not on the tracker: the tracker's uart_idle
module reads AT+CFUN=4 as modem sleep and turns the console off 2 s later, halfway through
the credential install. at_client is plain AT with the modem idle, and flashing it is harmless
here because step 6 erases everything anyway. Modem credentials live in the modem, so they
survive that erase.

Why the template is flashed separately: the tracker's merged.hex stops below 0xE0000
(SB_CONFIG_SOFTSIM_BUNDLE_TEMPLATE_HEX is off), and without the skeleton at nvs_storage the
SIM fails as "Failed to init FS", which looks like a bad profile.

Every build output is copied to att\artifacts\<slug>\, so the shared build dir can move on
to the next board.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $Iccid,
    [string] $Csv,
    [string] $Port,
    [string] $JLink,
    [string] $AttRoot        = "$PSScriptRoot\..\att",
    [string] $BuildDir       = 'build-icarus-new',
    [string] $ModemFirmware  = "$PSScriptRoot\firmware\mfw_nrf9160_1.3.7.zip",
    [string] $BoardsFile     = "$PSScriptRoot\secrets\boards.json",
    [switch] $SkipModemUpdate,
    [switch] $SkipCloud,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\env.ps1" | Out-Null
$AttRoot = [System.IO.Path]::GetFullPath($AttRoot)

$python   = 'C:\ncs\toolchains\dcbdc366a1\opt\bin\python.exe'
$objcopy  = 'C:\ncs\toolchains\dcbdc366a1\opt\zephyr-sdk\gnu\arm-zephyr-eabi\bin\arm-zephyr-eabi-objcopy.exe'
$board    = 'actinius_icarus@2.0.0/nrf9160/ns'
$slug     = ($Name.ToLower() -replace '[^a-z0-9]', '')
$secrets  = "$PSScriptRoot\secrets"
$atClient = "$PSScriptRoot\build-at-icarus\merged.hex"
$outDir   = Join-Path $AttRoot "artifacts\$slug"
$fragment = "$PSScriptRoot\profiles\softsim_static_profile_$slug.conf"
$caCert   = Get-ChildItem "$secrets\self_*_ca.pem"  | Select-Object -First 1
$caKey    = Get-ChildItem "$secrets\self_*_prv.pem" | Select-Object -First 1

function Step([string] $text) { Write-Host "`n== $text" -ForegroundColor Cyan }

# Native tools write progress to stderr. Under 'Stop', PS 5.1 turns a redirected stderr line
# into a terminating NativeCommandError even on exit 0, so relax it for the call only.
function Invoke-Native {
    param([string] $Exe, [string[]] $ArgList, [switch] $Quiet)
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @ArgList 2>&1 | ForEach-Object { "$_" }
    if (-not $Quiet) { $out | ForEach-Object { Write-Host "   $_" } }
    # Only the first two arguments in the message: nrf_cloud_onboard takes the API key as one.
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($ArgList[0..1] -join ' ') failed (exit $LASTEXITCODE):`n$($out -join "`n")" }
    return ($out -join "`n")
}

function Invoke-Nrfutil([string[]] $ArgList, [switch] $Quiet) {
    Invoke-Native -Exe 'nrfutil' -ArgList ($ArgList + @('--serial-number', $JLink)) -Quiet:$Quiet
}

# Returns the 32-bit words nrfutil prints, as hex strings.
function Read-Words([string] $Address, [int] $Bytes) {
    $text = Invoke-Nrfutil @('device', 'read', '--address', $Address, '--bytes', "$Bytes") -Quiet
    $words = @()
    foreach ($line in $text -split "`n") {
        if ($line -match '^0x[0-9A-Fa-f]+:\s+((?:[0-9A-Fa-f]{8}\s+)+)') {
            $words += ($Matches[1].Trim() -split '\s+')
        }
    }
    return $words
}

function Program([string] $Hex, [string] $EraseMode) {
    Invoke-Nrfutil @('device', 'program', '--firmware', $Hex, '--options', "chip_erase_mode=$EraseMode") -Quiet | Out-Null
}

# Monogoto's TLV profile: tag, 2-hex-char length in hex characters, value. Tag 02 is EF.ICCID,
# swapped-nibble BCD. Decoded from the profile rather than read from the CSV's ICCID column,
# because that column drops the 20th (Luhn) digit.
function Get-ProfileIccid([string] $Profile) {
    $i = 0
    while ($i -lt $Profile.Length) {
        $tag = $Profile.Substring($i, 2)
        $len = [Convert]::ToInt32($Profile.Substring($i + 2, 2), 16)
        $val = $Profile.Substring($i + 4, $len)
        if ($tag -eq '02') {
            $digits = for ($j = 0; $j -lt $val.Length; $j += 2) { $val[$j + 1]; $val[$j] }
            return (-join $digits).TrimEnd('F', 'f')
        }
        $i += 4 + $len
    }
    throw "Profile has no ICCID tag."
}

function Find-IcarusPort {
    $text = Invoke-Native -Exe 'nrfutil' -ArgList @('device', 'list') -Quiet
    $ports = foreach ($block in ($text -split "`n\s*`n")) {
        if ($block -match 'Icarus' -and $block -match 'Ports\s+(COM\d+)') { $Matches[1] }
    }
    $ports = @($ports | Where-Object { $_ })
    if ($ports.Count -eq 1) { return $ports[0] }
    if ($ports.Count -eq 0) { throw "No Icarus USB port found. Plug in the board, or pass -Port." }
    throw "More than one Icarus plugged in ($($ports -join ', ')). Pass -Port for the new one."
}

function Find-JLink {
    $text = Invoke-Native -Exe 'nrfutil' -ArgList @('device', 'list') -Quiet
    $serials = foreach ($block in ($text -split "`n\s*`n")) {
        if ($block -match 'Product\s+J-Link' -and $block.Trim() -match '^(\d+)') { $Matches[1] }
    }
    $serials = @($serials | Where-Object { $_ })
    if ($serials.Count -eq 1) { return $serials[0] }
    if ($serials.Count -eq 0) { throw "No J-Link found. Plug it in, or pass -JLink." }
    throw "More than one J-Link connected ($($serials -join ', ')). Pass -JLink for the one on the new board."
}

# Sends one line and collects output until $Until matches or the timeout passes.
function Send-Console([string] $Line, [string] $Until = '\r?\n(OK|ERROR)', [int] $TimeoutMs = 5000) {
    $sp = New-Object System.IO.Ports.SerialPort $Port, 115200
    $sp.Open()
    try {
        $sp.DiscardInBuffer()
        if ($Line) { $sp.Write("$Line`r`n") }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $buf = ''
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            $buf += $sp.ReadExisting()
            if ($buf -match $Until) { break }
            Start-Sleep -Milliseconds 200
        }
        return ($buf -replace '\x1b\[[0-9;]*[A-Za-z]', '')
    } finally { $sp.Close() }
}

function Wait-AtReady([int] $TimeoutS = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutS)
    while ((Get-Date) -lt $deadline) {
        if ((Send-Console 'AT' -TimeoutMs 1500) -match '\bOK\b') { return }
    }
    throw "No AT response on $Port within $TimeoutS s."
}

# ---- 1. Preflight ------------------------------------------------------------------------
Step "1/8 Preflight"

foreach ($f in $atClient, $ModemFirmware, $caCert, $caKey, "$secrets\nrfcloud.json", $objcopy) {
    if (-not $f -or -not (Test-Path $f)) { throw "Missing: $f" }
}
if (-not $JLink) { $JLink = Find-JLink }
if (-not $Port) { $Port = Find-IcarusPort }
Write-Host "   console $Port, J-Link $JLink"

$registry = @()
if (Test-Path $BoardsFile) { $registry = Get-Content $BoardsFile -Raw | ConvertFrom-Json }
if ($registry | Where-Object { $_.name -eq $Name }) { throw "'$Name' is already in $BoardsFile." }

try { $boot = Read-Words '0x0' 8 }
catch {
    if ("$_" -match 'LOW_VOLTAGE') { throw "J-Link sees no powered target. Check the SWD cable and board power." }
    throw
}
$sim = Read-Words '0xF0000' 16
Write-Host "   0x0: $($boot -join ' ')   0xF0000: $($sim -join ' ')"
# '30306633' is "3f00" -- the SoftSIM filesystem's root path. '00000AED' is the tracker's b0.
if (-not $Force) {
    if ($sim -contains '30306633') {
        throw "This board already holds a SoftSIM filesystem at 0xF0000. Step 6 would erase it. -Force to proceed anyway."
    }
    if ($boot[1] -eq '00000AED') {
        throw "This board already runs the tracker's b0 bootloader. Wrong board on the J-Link? -Force to proceed anyway."
    }
}

# ---- 2. SIM ------------------------------------------------------------------------------
Step "2/8 SIM"

$csvFiles = if ($Csv) { @(Get-Item $Csv) } else { @(Get-ChildItem "$PSScriptRoot\*.csv") }
$sims = foreach ($f in $csvFiles) {
    foreach ($row in (Import-Csv $f.FullName)) {
        $p = "$($row.Profile)".Trim()
        if ($p -match '^[0-9A-Fa-f]{100,}$') {
            [pscustomobject]@{ Iccid = (Get-ProfileIccid $p); Profile = $p; Csv = $f.Name }
        }
    }
}
$sims = @($sims | Where-Object { $_ })
if ($sims.Count -eq 0) { throw "No SoftSIM rows found in: $($csvFiles.Name -join ', ')" }

$used = @($registry | ForEach-Object { $_.iccid })
$pick = if ($Iccid) { $sims | Where-Object { $_.Iccid -eq $Iccid } | Select-Object -First 1 }
        else        { $sims | Where-Object { $used -notcontains $_.Iccid } | Select-Object -First 1 }
if (-not $pick) {
    if ($Iccid) { throw "ICCID $Iccid is in none of: $($csvFiles.Name -join ', ')" }
    throw "Every SIM in $($csvFiles.Name -join ', ') is already assigned in $BoardsFile. Order more."
}
if ($used -contains $pick.Iccid) { Write-Warning "ICCID $($pick.Iccid) is already used by another board." }
Write-Host "   ICCID $($pick.Iccid) from $($pick.Csv)"

# A copy of the shared fragment with only the profile swapped, so Memfault and the rest stay
# identical across boards. Written without a BOM: Kconfig rejects one as a malformed line.
$template = Get-Content "$PSScriptRoot\profiles\softsim_static_profile.conf"
$lines = @("# $Name`: Monogoto SoftSIM ICCID $($pick.Iccid) ($($pick.Csv)). Written by New-IcarusBoard.ps1.")
$lines += $template | ForEach-Object {
    if ($_ -like 'CONFIG_SOFTSIM_STATIC_PROFILE=*') { "CONFIG_SOFTSIM_STATIC_PROFILE=`"$($pick.Profile)`"" } else { $_ }
}
[System.IO.File]::WriteAllLines($fragment, [string[]]$lines, (New-Object System.Text.UTF8Encoding $false))

# ---- 3. Build (background) -----------------------------------------------------------------
Step "3/8 Tracker build started in the background ($AttRoot\$BuildDir)"

$buildLog = Join-Path $AttRoot "$BuildDir.log"
$conf = "$AttRoot/project/examples/modules/cloud/overlay-nrfcloud-coap.conf;$fragment" -replace '\\', '/'
$modules = "$PSScriptRoot/modules/onomondo-softsim" -replace '\\', '/'
$build = Start-Job -ArgumentList $PSScriptRoot, $AttRoot, $board, $BuildDir, $modules, $conf, $buildLog -ScriptBlock {
    param($repo, $att, $board, $dir, $modules, $conf, $log)
    . "$repo\env.ps1" | Out-Null
    Set-Location $att
    west build -b $board -d $dir project\app -- "-DEXTRA_ZEPHYR_MODULES=$modules" "-DEXTRA_CONF_FILE=$conf" *> $log
    $LASTEXITCODE
}

try {
    # ---- 4. Modem --------------------------------------------------------------------------
    if ($SkipModemUpdate) { Step "4/8 Modem update skipped" }
    else {
        Step "4/8 Modem firmware -> 1.3.7 (~2 min)"
        # A modem zip goes to the modem's own flash; app flash, IMEI and eSIM are untouched.
        Invoke-Nrfutil @('device', 'program', '--firmware', $ModemFirmware) -Quiet | Out-Null
    }

    # ---- 5. Cloud --------------------------------------------------------------------------
    Step "5/8 at_client, IMEI, nRF Cloud"
    Program $atClient 'ERASE_ALL'
    Invoke-Nrfutil @('device', 'reset') -Quiet | Out-Null
    Wait-AtReady

    $cgmr = Send-Console 'AT+CGMR'
    if ($cgmr -notmatch 'mfw_nrf9160_1\.3\.(\d+)' -or [int]$Matches[1] -lt 4) {
        throw "Modem firmware too old for SoftSIM:`n$cgmr"
    }
    $imei = if ((Send-Console 'AT+CGSN') -match '\b(\d{15})\b') { $Matches[1] } else { throw "Could not read IMEI." }
    $deviceId = "nrf-$imei"
    Write-Host "   $deviceId, modem $(([regex]'mfw_nrf9160_[\d.]+').Match($cgmr).Value)"

    if ($SkipCloud) { Write-Host "   cloud onboarding skipped" }
    else {
        $onboardCsv = "onboard-$slug.csv"
        Push-Location $secrets
        try {
            Invoke-Native -Exe $python -ArgList @('-m', 'nrfcloud_utils.device_credentials_installer',
                '--ca', $caCert.Name, '--ca-key', $caKey.Name, '--id-str', 'nrf-', '--id-imei',
                '-s', '-d', '--verify', '--coap', '--port', $Port, '--rtscts-off', '--cmd-type', 'at',
                '--csv', $onboardCsv) -Quiet | Out-Null
            $apiKey = (Get-Content "$secrets\nrfcloud.json" -Raw | ConvertFrom-Json).apiKey
            $result = Invoke-Native -Exe $python -ArgList @('-m', 'nrfcloud_utils.nrf_cloud_onboard',
                '--api-key', $apiKey, '--csv', $onboardCsv) -Quiet
        } finally { Pop-Location }
        if ($result -notmatch 'SUCCEEDED' -or $result -notmatch "$deviceId,OK") {
            throw "nRF Cloud onboarding did not report $deviceId,OK:`n$result"
        }
        Write-Host "   credentials installed, $deviceId onboarded"
    }

    # ---- wait for the build ----------------------------------------------------------------
    Step "   waiting for the tracker build (log: $buildLog)"
    $code = Receive-Job $build -Wait
    if ("$code" -ne '0') { throw "Tracker build failed (exit $code). See $buildLog" }
} finally {
    if ($build.State -eq 'Running') { Stop-Job $build }
    Remove-Job $build -Force
}

$bdir = Join-Path $AttRoot $BuildDir
# The shared build dir must actually carry this board's profile, not the previous board's.
if (-not (Select-String "$bdir\app\zephyr\.config" -SimpleMatch "CONFIG_SOFTSIM_STATIC_PROFILE=`"$($pick.Profile)`"" -Quiet)) {
    throw "$bdir does not contain the chosen profile. Refusing to flash."
}

New-Item -ItemType Directory -Force $outDir | Out-Null
foreach ($f in 'merged.hex', 'app\zephyr\zephyr.signed.hex', 'dfu_mcuboot.zip', 'app_provision.hex') {
    Copy-Item (Join-Path $bdir $f) $outDir
}
$templateHex = Join-Path $outDir 'softsim_template_0xF0000.hex'
Invoke-Native -Exe $objcopy -ArgList @('--input-target=binary', '--output-target=ihex',
    '--change-address', '0xF0000', "$PSScriptRoot\modules\onomondo-softsim\lib\profile\template.bin",
    $templateHex) -Quiet | Out-Null

# ---- 6. Flash ------------------------------------------------------------------------------
Step "6/8 Flash tracker + SoftSIM template"
Program "$outDir\merged.hex" 'ERASE_ALL'
Program $templateHex 'ERASE_NONE'   # the region is blank after ERASE_ALL, so no erase is needed

$b0   = Read-Words '0x0' 8
$fs   = Read-Words '0xF0000' 16
$uicr = Read-Words '0xFF8130' 8
if ($b0[1] -ne '00000AED')        { throw "b0 not at 0x0 after flashing: $($b0 -join ' ')" }
if ($fs -notcontains '30306633')  { throw "SoftSIM template not at 0xF0000: $($fs -join ' ')" }
if ($uicr[0] -eq 'FFFFFFFF')      { throw "UICR provision page is blank; b0 will not boot." }
Write-Host "   b0, template and UICR provision page all in place"

# ---- 7. Verify -----------------------------------------------------------------------------
Step "7/8 Boot and connect (up to 90 s)"
$sp = New-Object System.IO.Ports.SerialPort $Port, 115200
$sp.Open()
try {
    $sp.DiscardInBuffer()
    Invoke-Nrfutil @('device', 'reset') -Quiet | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = ''
    while ($sw.ElapsedMilliseconds -lt 90000) {
        $log += $sp.ReadExisting()
        if ($log -match 'Connected to Cloud|Failed to init FS|SoftSIM failed') { Start-Sleep 1; $log += $sp.ReadExisting(); break }
        Start-Sleep -Milliseconds 250
    }
} finally { $sp.Close() }
$log = $log -replace '\x1b\[[0-9;]*[A-Za-z]', ''
$log | Set-Content (Join-Path $outDir 'first-boot.log') -Encoding utf8

$log -split "`n" | Where-Object { $_ -match 'PDN connection activated|client ID|Connected to Cloud|<err>' } |
    ForEach-Object { Write-Host "   $($_.Trim())" }
if ($log -notmatch 'Connected to Cloud') {
    throw "No 'Connected to Cloud' within 90 s. Boot log: $outDir\first-boot.log"
}
if ($log -notmatch [regex]::Escape($deviceId)) { Write-Warning "Connected, but the client ID in the log is not $deviceId." }

# ---- 8. Register ---------------------------------------------------------------------------
Step "8/8 Register"
$entry = [pscustomobject]@{
    name      = $Name
    deviceId  = $deviceId
    iccid     = $pick.Iccid
    board     = 'actinius_icarus'
    csv       = $pick.Csv
    artifacts = $outDir
    onboarded = (Get-Date -Format 'yyyy-MM-dd')
}
$all = @($registry | Where-Object { $_ }) + $entry
ConvertTo-Json -InputObject $all -Depth 3 | Set-Content $BoardsFile -Encoding utf8

Write-Host "`n$Name is live: $deviceId on ICCID $($pick.Iccid)." -ForegroundColor Green
Write-Host "It appears on the map at the next refresh. Artifacts: $outDir" -ForegroundColor Green
