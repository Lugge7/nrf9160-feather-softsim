<#
Serial console monitor for the Feather. Companion to flash.ps1.

    .\monitor.ps1              # listen on COM15 @115200 until Ctrl+C
    .\monitor.ps1 -Seconds 60  # listen for a fixed window
    .\monitor.ps1 -Send 'AT+CEREG?'   # send an AT command, then keep listening
    .\monitor.ps1 -Log gnss.txt       # also append to a file, every line prefixed with
                                      # seconds since the script started. Use this for the
                                      # A-GNSS and TTFF runs so the timing survives.

Run it, then tap RST (hold nothing) to capture the boot banner from t=0.
#>
param(
    [string]$Port    = 'COM15',
    [int]   $Baud    = 115200,
    [int]   $Seconds = 0,          # 0 = until Ctrl+C
    [string]$Send    = '',
    [string]$Log     = ''          # '' = console only
)

$ErrorActionPreference = 'Stop'

$ports = [System.IO.Ports.SerialPort]::GetPortNames()
if ($ports -notcontains $Port) { throw "$Port not present. Available: $($ports -join ', ')" }

$p = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$p.ReadTimeout = 500
$p.Open()
Write-Host "$Port @ $Baud -- tap RST to see the boot banner. Ctrl+C to stop." -ForegroundColor Cyan

if ($Send) {
    Start-Sleep -Milliseconds 200
    $p.Write("$Send`r`n")
    Write-Host ">>> $Send" -ForegroundColor Yellow
}

$t0 = Get-Date
if ($Log) {
    if (-not [System.IO.Path]::IsPathRooted($Log)) { $Log = Join-Path (Get-Location) $Log }
    $Log = [System.IO.Path]::GetFullPath($Log)
    "=== $Port @ $Baud  started $($t0.ToString('yyyy-MM-dd HH:mm:ss')) ===" |
        Out-File -FilePath $Log -Append -Encoding utf8
    Write-Host "logging to $Log" -ForegroundColor Cyan
}

$deadline = if ($Seconds -gt 0) { (Get-Date).AddSeconds($Seconds) } else { [DateTime]::MaxValue }
try {
    while ((Get-Date) -lt $deadline) {
        try {
            $line = $p.ReadLine()
            if ($line.Trim()) {
                Write-Host $line.TrimEnd()
                if ($Log) {
                    $el = ((Get-Date) - $t0).TotalSeconds
                    ('[{0,8:F2}] {1}' -f $el, $line.TrimEnd()) |
                        Out-File -FilePath $Log -Append -Encoding utf8
                }
            }
        }
        catch [TimeoutException] { }
    }
} finally {
    if ($p.IsOpen) { $p.Close() }
    Write-Host "`n(closed $Port)" -ForegroundColor DarkGray
}
