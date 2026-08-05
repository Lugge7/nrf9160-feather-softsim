<#
Fetch a Monogoto SoftSIM profile for the nRF9160 Feather.

Credentials are read from secrets\monogoto.json (gitignored) so they never end
up in a shell history or a chat log. Copy secrets\monogoto.example.json to
secrets\monogoto.json and fill it in.

    .\Get-SoftSimProfile.ps1              # profile as data  (hexfile=false) - what we want
    .\Get-SoftSimProfile.ps1 -HexFile     # HEX image        (hexfile=true)  - needs a SWD probe

Docs: https://docs.monogoto.io/developer/api/softsim-nordic
#>
param(
    [switch]$HexFile,
    [string]$ConfigPath = "$PSScriptRoot\secrets\monogoto.json",
    [string]$OutDir     = "$PSScriptRoot\profiles"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ConfigPath)) {
    throw "Config not found: $ConfigPath`nCopy secrets\monogoto.example.json to secrets\monogoto.json and fill it in."
}

$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
foreach ($f in 'UserName','Password','iccid','imsi','ki','opc') {
    if (-not $cfg.$f) { throw "Missing '$f' in $ConfigPath" }
}

# The Monogoto docs use these as illustrative values. Provisioning them yields a
# SoftSIM that fails network authentication, which is painful to diagnose later.
$placeholders = @('00112233445566778899AABBCCDDEEFF', 'FFEEDDCCBBAA99887766554433221100')
if ($placeholders -contains $cfg.ki.ToUpper() -or $placeholders -contains $cfg.opc.ToUpper()) {
    throw "ki/opc are the documentation's example values, not real SIM credentials. Get the real ones from the Monogoto console (Thing -> Mobile Identities)."
}
foreach ($f in 'ki','opc') {
    if ($cfg.$f -notmatch '^[0-9A-Fa-f]{32}$') { throw "'$f' must be 32 hex characters (128-bit). Got: $($cfg.$f.Length) chars." }
}
if ($cfg.iccid.Length -lt 19 -or $cfg.iccid.Length -gt 20) { throw "iccid must be 19 or 20 characters. Got $($cfg.iccid.Length)." }

$device = 'nRF9160'
if ($cfg.device) { $device = $cfg.device }

# --- 1. Authenticate -------------------------------------------------------
Write-Host "Authenticating as $($cfg.UserName)..." -ForegroundColor Cyan
$auth = Invoke-RestMethod -Method Post -Uri 'https://console.monogoto.io/Auth' `
    -ContentType 'application/json' `
    -Body (@{ UserName = $cfg.UserName; Password = $cfg.Password } | ConvertTo-Json)

if (-not $auth.token) { throw "No token in auth response." }
$hdr = @{ Authorization = "Bearer $($auth.token)" }
Write-Host "  ok - CustomerId $($auth.CustomerId)" -ForegroundColor Green

# --- 2. Generate -----------------------------------------------------------
$body = @{
    iccid   = $cfg.iccid
    imsi    = $cfg.imsi
    ki      = $cfg.ki
    opc     = $cfg.opc
    device  = $device
    hexfile = [bool]$HexFile
} | ConvertTo-Json

Write-Host "Generating profile (hexfile=$([bool]$HexFile)) for ICCID $($cfg.iccid)..." -ForegroundColor Cyan
$gen = Invoke-RestMethod -Method Post -Headers $hdr -ContentType 'application/json' `
    -Uri "https://api.monogoto.io/v1/things/$($cfg.iccid)/softsim/nordic/generate" -Body $body

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if (-not $HexFile) {
    # Profile returned inline - this is the route that needs no debug probe.
    $out = "$OutDir\profile-$($cfg.iccid)-$stamp.json"
    $gen | ConvertTo-Json -Depth 12 | Set-Content $out -Encoding utf8
    Write-Host "Profile written to $out" -ForegroundColor Green
    Write-Host "Top-level fields: $(($gen.PSObject.Properties.Name) -join ', ')"
    return
}

# --- 3. Poll task status ---------------------------------------------------
$taskId = $gen.task_id
if (-not $taskId) { $taskId = $gen.taskId }
if (-not $taskId) { throw "No task_id in generate response: $($gen | ConvertTo-Json -Compress)" }
Write-Host "  task_id $taskId" -ForegroundColor Green

$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 5
    $st = Invoke-RestMethod -Method Get -Headers $hdr `
        -Uri "https://api.monogoto.io/v1/things/$($cfg.iccid)/softsim/nordic/task/$taskId"
    Write-Host "  status: $($st.status)  $($st.message)"
} while ($st.status -notmatch 'complete|success|done|ready' -and (Get-Date) -lt $deadline)

# --- 4. Download -----------------------------------------------------------
$out = "$OutDir\softsim-$($cfg.iccid)-$stamp.hex"
Invoke-WebRequest -Headers $hdr -UseBasicParsing `
    -Uri "https://api.monogoto.io/v1/things/$($cfg.iccid)/softsim/nordic/download/$taskId" -OutFile $out

Write-Host "HEX written to $out" -ForegroundColor Green
Write-Host "Note: flashing this needs SWD (nRF Connect Programmer). The Feather has no onboard debugger." -ForegroundColor Yellow
