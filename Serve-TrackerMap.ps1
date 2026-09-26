<#
Serves the tracker map over Tailscale so it can be opened on a phone.

    .\Serve-TrackerMap.ps1 -Tailscale       # https://<host>.ts.net/ on your phone,
                                            # re-pulling every minute by default
    .\Serve-TrackerMap.ps1 -Tailscale -Watch 0.5 -PollSeconds 10   # ~40 s cloud to screen
    .\Serve-TrackerMap.ps1 -Tailscale -Refresh   # pull fresh history before serving
    .\Serve-TrackerMap.ps1 -Watch 0         # static: serve the page exactly as built
    .\Serve-TrackerMap.ps1                  # localhost:8081 only, to check the page renders

Three delays sit between a fix and the screen, and only the last two are ours:

    device -> nRF Cloud   the firmware's own sampling interval, 120 s while moving
    cloud  -> disk        -Watch minutes, default 1
    disk   -> page        -PollSeconds, default 20

A pull plus a rebuild takes about 2.3 s, so the middle one is cheap to shorten; the
refresher floors its sleep at 5 s so a mistyped -Watch cannot busy-loop the API. The page
poll only reads a file off this server and returns early when nothing changed, so it costs
nothing upstream. Shortening either does nothing for the first delay -- a tracker asleep on
PSM reports when it reports, and no amount of polling makes a fix exist sooner.
    .\Serve-TrackerMap.ps1 -Bind tailscale  # bind the 100.x address directly (needs a
                                            # firewall rule; see below)

**The recommended path is -Tailscale, and it is the one that needs no administrator.**
The server listens on 127.0.0.1 and `tailscale serve` proxies the tailnet HTTPS endpoint
to it. Nothing listens on a real interface at all, so Windows Firewall never enters into
it and there is no rule to add, forget about, or get wrong. Access control is tailscaled's:
only devices on the tailnet can reach the proxy.

Two Windows-specific limits shaped this, both discovered the hard way:

  `tailscale serve <directory>` refuses with "must be a Windows local admin to serve a
  path or Unix socket". Proxying a *port* has no such restriction, hence the local server.

  Binding this server to the 100.x address instead works, but Windows Firewall drops the
  inbound connections and unblocking them needs an elevated
  New-NetFirewallRule. -Bind tailscale is kept for that case; it is strictly more exposed
  and strictly more setup, so it is no longer the default.

`tailscale serve --bg` persists across reboots but this script does not, so after a
restart the tailnet URL will 502 until it is started again. `tailscale serve --https=443
off` removes the proxy.

**It serves a directory that holds nothing but the map.** The repo root contains
secrets\ (nRF Cloud and Monogoto API keys) and profiles\ (the SoftSIM profile and the
Memfault key). Pointing any web server at the repo root would publish all of it to every
device on the tailnet. -Root defaults to .\publish for that reason; keep it that way.

TcpListener rather than HttpListener: HttpListener needs an admin-registered URL ACL for
any prefix that is not localhost. A GET-only static server is small enough to do directly.
#>
param(
    [string] $Root    = 'publish',
    [int]    $Port    = 8081,
    [string] $Bind    = 'loopback',
    [switch] $Tailscale,
    [switch] $Refresh,
    # Minutes between nRF Cloud pulls, and fractional on purpose: -Watch 0.5 is 30 s. A
    # pull plus a rebuild measures about 2.3 s, so a sub-minute tick is affordable, and the
    # loop floors the sleep at 5 s regardless. 0 disables the refresher entirely.
    #
    # Defaulted on rather than off. At 0 the page still polls, finds a points.json that
    # nothing rewrites, and sits on build-time data forever -- live-looking and stale, with
    # nothing on screen to distinguish the two.
    [double] $Watch   = 1,
    # Seconds between the page re-reading points.json. Passed to New-TrackerMap.ps1 so the
    # page and this script cannot drift apart.
    [int]    $PollSeconds = 20
)

$ErrorActionPreference = 'Stop'

$tailscaleExe = 'C:\Program Files\Tailscale\tailscale.exe'

function Get-TailscaleIPv4 {
    if (-not (Test-Path $tailscaleExe)) { throw "Tailscale not found at $tailscaleExe" }
    $status = & $tailscaleExe status --json 2>$null | ConvertFrom-Json
    if ($status.BackendState -ne 'Running') {
        throw "Tailscale is $($status.BackendState), not Running. Run: tailscale up"
    }
    $v4 = @($status.Self.TailscaleIPs | Where-Object { $_ -notmatch ':' })
    if ($v4.Count -eq 0) { throw 'No Tailscale IPv4 address found.' }
    return @{ IP = $v4[0]; Name = $status.Self.DNSName.TrimEnd('.') }
}

if ($Refresh) {
    Write-Host 'Refreshing location history...' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'Get-TrackerHistory.ps1') -Out 'track.json'
    & (Join-Path $PSScriptRoot 'New-TrackerMap.ps1') -In 'track.json' -Out (Join-Path $Root 'map.html') -PollSeconds $PollSeconds
}

# An absolute -Root must not be joined against the working directory: Join-Path happily
# produces "C:\repo\C:\elsewhere", and GetFullPath then fails with "The given path's format
# is not supported" rather than anything that names the real problem. New-TrackerMap.ps1
# and Get-TrackerHistory.ps1 already guard their own path parameters this way.
$rootFull = if ([System.IO.Path]::IsPathRooted($Root)) {
    [System.IO.Path]::GetFullPath($Root)
} else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Root))
}
if (-not (Test-Path $rootFull)) { throw "$rootFull does not exist. Run New-TrackerMap.ps1 -Out $Root\map.html first." }

# "/" resolves to map.html rather than to a copy at index.html. One file means the watch
# loop has one thing to replace atomically; a second copy would be briefly out of step with
# points.json every time it rebuilt.
$mapFile = Join-Path $rootFull 'map.html'
if (-not (Test-Path $mapFile)) { throw "$mapFile not found. Run New-TrackerMap.ps1 -Out $Root\map.html first." }
Remove-Item (Join-Path $rootFull 'index.html') -Force -ErrorAction SilentlyContinue

switch ($Bind) {
    'tailscale' { $ts = Get-TailscaleIPv4; $bindIP = $ts.IP; $hostName = $ts.Name }
    'loopback'  { $bindIP = '127.0.0.1';   $hostName = 'localhost' }
    default     { $bindIP = $Bind;         $hostName = $Bind }
}

$mime = @{
    '.html' = 'text/html; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.png'  = 'image/png'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
}

$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Parse($bindIP)), $Port
try { $listener.Start() }
catch { throw "Could not bind ${bindIP}:${Port} -- $($_.Exception.Message)" }

Write-Host ''
Write-Host ("  Serving {0}" -f $rootFull) -ForegroundColor Cyan

if ($Tailscale) {
    if ($Bind -ne 'loopback') {
        Write-Warning '-Tailscale proxies to 127.0.0.1; -Bind is ignored for the proxy target.'
    }
    $ts = Get-TailscaleIPv4

    # --bg so the proxy outlives this shell, and so it is already in place on the next run.
    $out = & $tailscaleExe serve --bg $Port 2>&1
    if ($LASTEXITCODE -ne 0) {
        $listener.Stop()
        throw ("tailscale serve failed: {0}" -f ($out -join ' '))
    }

    Write-Host ("  On your phone, open:  https://{0}/" -f $ts.Name) -ForegroundColor Green
    Write-Host '  (tailnet only -- nothing is listening on a real interface)' -ForegroundColor DarkGray
    Write-Host '  Remove the proxy later with: tailscale serve --https=443 off' -ForegroundColor DarkGray
} else {
    Write-Host ("  Open:  http://{0}:{1}/" -f $hostName, $Port) -ForegroundColor Green
    if ($Bind -eq 'loopback') {
        Write-Host '  Local only. Add -Tailscale to reach it from your phone.' -ForegroundColor DarkGray
    }
}
$watchJob = $null
if ($Watch -gt 0) {
    # A job rather than work inside the accept loop: Get-TrackerHistory pages through the
    # nRF Cloud API and takes several seconds, which would stall every request that landed
    # during it. The job dies with this process, which is what we want -- a refresher still
    # running after the server is gone would rewrite files nothing is serving.
    $watchJob = Start-Job -Name 'tracker-refresh' -ScriptBlock {
        param($scriptRoot, $workDir, $root, $minutes, $skipFirst, $pollSeconds)
        Set-Location $workDir
        $tmp = Join-Path $root '_map.tmp.html'
        $final = Join-Path $root 'map.html'

        # Sleep at the END of the loop, not the start. Sleeping first left the page showing
        # build-time data for a whole interval after startup with nothing to say why, which
        # read as "the refresh is broken" rather than "the refresh has not run yet".
        # -Refresh has already pulled synchronously by this point, so that one case skips
        # straight to the sleep instead of pulling the same data twice seconds apart.
        $first = $true
        while ($true) {
            if ($first -and $skipFirst) {
                $first = $false
                Start-Sleep -Seconds ([math]::Max(5, [int]($minutes * 60)))
                continue
            }
            $first = $false
            try {
                & (Join-Path $scriptRoot 'Get-TrackerHistory.ps1') -Out 'track.json' | Out-Null
                # Built under a temp name and moved into place, so a request that arrives
                # mid-rebuild gets the previous complete page rather than half of the next
                # one. New-TrackerMap.ps1 writes points.json beside it, already atomically.
                & (Join-Path $scriptRoot 'New-TrackerMap.ps1') -In 'track.json' -Out $tmp -PollSeconds $pollSeconds | Out-Null
                Move-Item -LiteralPath $tmp -Destination $final -Force
            } catch {
                # A failed refresh is not fatal -- the cloud can be briefly unreachable and
                # the page keeps serving the last good build until the next tick -- but it
                # must not be invisible. A bare `catch {}` here hid a broken rebuild for
                # hours: track.json kept updating, the page never did, and nothing said so.
                # The job's own output stream goes nowhere useful, hence the file.
                # Written to the working directory, not $root: anything under $root is
                # served, and an error log carries absolute paths.
                $line = '{0}  {1}' -f (Get-Date -Format 's'), $_.Exception.Message
                Add-Content -LiteralPath (Join-Path $workDir 'refresh-errors.log') -Value $line
            }
            # Floored at 5 s so a mistyped -Watch cannot turn into a busy loop against the
            # nRF Cloud API. A pull plus a rebuild measures about 2.3 s, so anything under
            # that would overlap itself anyway.
            Start-Sleep -Seconds ([math]::Max(5, [int]($minutes * 60)))
        }
    } -ArgumentList $PSScriptRoot, (Get-Location).Path, $rootFull, $Watch, [bool]$Refresh, $PollSeconds

    $secs = [math]::Max(5, [int]($Watch * 60))
    Write-Host ("  Re-pulling history every {0} s (page polls every {1} s)" -f $secs, $PollSeconds) -ForegroundColor Cyan
    Write-Host ("  Worst case cloud to screen: {0} s" -f ($secs + $PollSeconds)) -ForegroundColor DarkGray
} else {
    Write-Host '  -Watch 0: no refresher. The page will keep showing the data it was built with.' -ForegroundColor DarkYellow
}

Write-Host '  Ctrl+C to stop.' -ForegroundColor DarkGray
Write-Host ''

function Send-Response {
    param($Stream, [int] $Code, [string] $Status, [string] $Type, [byte[]] $Body)
    $head = "HTTP/1.1 $Code $Status`r`n" +
            "Content-Type: $Type`r`n" +
            "Content-Length: $($Body.Length)`r`n" +
            # The page is rebuilt in place, so a cached copy on the phone would show
            # yesterday's track after a -Refresh with no way to tell.
            "Cache-Control: no-store`r`n" +
            "Connection: close`r`n`r`n"
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($Body.Length) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.ReceiveTimeout = 5000
            $client.SendTimeout    = 15000
            $stream = $client.GetStream()

            # Read just the request line and headers. Nothing here accepts a body.
            $sb = New-Object System.Text.StringBuilder
            $buf = New-Object byte[] 2048
            while ($sb.ToString() -notmatch "`r`n`r`n") {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -le 0) { break }
                $null = $sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
                if ($sb.Length -gt 16384) { break }
            }

            $requestLine = ($sb.ToString() -split "`r`n")[0]
            $parts = $requestLine -split ' '
            $method = $parts[0]
            $target = if ($parts.Count -gt 1) { $parts[1] } else { '/' }
            $path = ($target -split '\?')[0]
            if ($path -eq '/' -or $path -eq '/index.html') { $path = '/map.html' }

            if ($method -ne 'GET' -and $method -ne 'HEAD') {
                Send-Response $stream 405 'Method Not Allowed' 'text/plain; charset=utf-8' `
                    ([System.Text.Encoding]::UTF8.GetBytes('Only GET is served here.'))
                continue
            }

            # Resolve inside the root and refuse anything that escapes it. Without this a
            # request for /../secrets/nrfcloud.json would hand out the API key.
            $rel = [System.Uri]::UnescapeDataString($path.TrimStart('/')) -replace '/', '\'
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $rootFull $rel))
            $inRoot = $candidate.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar,
                                            [System.StringComparison]::OrdinalIgnoreCase)

            if (-not $inRoot -or -not (Test-Path $candidate -PathType Leaf)) {
                Write-Host ("  404 {0}" -f $path) -ForegroundColor DarkYellow
                Send-Response $stream 404 'Not Found' 'text/plain; charset=utf-8' `
                    ([System.Text.Encoding]::UTF8.GetBytes('Not found'))
                continue
            }

            $ext = [System.IO.Path]::GetExtension($candidate).ToLowerInvariant()
            $type = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
            $bytes = [System.IO.File]::ReadAllBytes($candidate)
            if ($method -eq 'HEAD') { $bytes = New-Object byte[] 0 }

            Write-Host ("  200 {0}  ({1:N0} bytes)" -f $path, $bytes.Length) -ForegroundColor DarkGray
            Send-Response $stream 200 'OK' $type $bytes
        }
        catch {
            Write-Host ("  request failed: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
        }
        finally {
            if ($client) { $client.Close() }
        }
    }
}
finally {
    $listener.Stop()
    if ($watchJob) {
        Stop-Job   $watchJob -ErrorAction SilentlyContinue
        Remove-Job $watchJob -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Stopped.' -ForegroundColor DarkGray
}
