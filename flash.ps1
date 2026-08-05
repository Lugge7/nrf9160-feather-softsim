<#
Flash the built app to the nRF9160 Feather over MCUboot serial DFU.

The board must already be in bootloader mode:
    1. Hold MODE
    2. Tap RST while still holding MODE
    3. Keep holding MODE until the blue LED lights

Then:  .\flash.ps1
#>
param(
    [string]$Port  = 'COM15',
    [int]   $Baud  = 1000000,
    [string]$Image = "$PSScriptRoot\build\blinky\zephyr\zephyr.signed.bin"
)

$ErrorActionPreference = 'Stop'
$newtmgr = "$PSScriptRoot\tools\newtmgr\newtmgr.exe"

if (-not (Test-Path $newtmgr)) { throw "newtmgr not found: $newtmgr" }
if (-not (Test-Path $Image))   { throw "image not found: $Image  (run the build first)" }

$ports = [System.IO.Ports.SerialPort]::GetPortNames()
if ($ports -notcontains $Port) {
    throw "$Port not present. Available: $($ports -join ', ')"
}

$connstring = "dev=$Port,baud=$Baud,mtu=512"
$sizeKB = [math]::Round((Get-Item $Image).Length / 1KB, 1)
Write-Host "Uploading $sizeKB KB to $Port at $Baud baud..." -ForegroundColor Cyan

& $newtmgr --conntype serial --connstring $connstring -t 60 -r 3 image upload $Image
if ($LASTEXITCODE -ne 0) { throw "image upload failed (exit $LASTEXITCODE). Is the board in bootloader mode?" }

Write-Host "Upload done. Resetting..." -ForegroundColor Cyan
& $newtmgr --conntype serial --connstring $connstring -t 20 reset

Write-Host "Flashed. Blue LED D7 should blink at 1 Hz." -ForegroundColor Green
Write-Host "Serial console: $Port @ 115200" -ForegroundColor Green
