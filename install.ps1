<#
.SYNOPSIS
    One-liner installer for session-broker (Windows).

.DESCRIPTION
    Downloads the latest release, extracts it to the install directory, registers
    the scheduled task, and starts it. Re-running updates in place and preserves
    config.json, token.txt and logs\.

    The folder it extracts into IS the install - there is no separate copy step.

.EXAMPLE
    # install / update
    irm https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/install.ps1 | iex

    # custom directory
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/install.ps1))) -InstallDir D:\apps\sb

    # prerelease channel
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/install.ps1))) -Channel beta
#>
param(
    [string]$InstallDir = 'C:\Tools\session-broker',
    [ValidateSet('latest', 'beta')]
    [string]$Channel = 'latest',
    [int]$Port = 7700,
    [string]$TaskName = 'SessionBroker'
)

$ErrorActionPreference = 'Stop'
$repo = 'mepapps/caldwell-session-broker-releases'

function Info($m) { Write-Host "  $m" }
function Good($m) { Write-Host "  $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  $m" -ForegroundColor Red }

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   session-broker - Installer" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""

# --- elevation ---------------------------------------------------------------
# The scheduled task must be registered with RunLevel Highest, and on a host
# where UAC is enabled a normally-launched process holds the FILTERED token -
# so registration fails or the broker ends up unprivileged. Re-launch elevated
# rather than half-installing.
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole('Administrators')) {
    Warn "Elevation required (the broker's task runs with highest privileges)."
    Info "Relaunching as administrator..."

    $args = "-NoProfile -ExecutionPolicy Bypass -Command ""& ([scriptblock]::Create((irm https://raw.githubusercontent.com/$repo/main/install.ps1))) -InstallDir '$InstallDir' -Channel '$Channel' -Port $Port -TaskName '$TaskName'; Write-Host ''; Read-Host 'Press Enter to close'"""
    try {
        Start-Process powershell -Verb RunAs -ArgumentList $args
        Info "Installer opened in an elevated window."
    } catch {
        Bad "Could not elevate: $_"
        Info "Open an elevated PowerShell and re-run the install command."
    }
    return
}

# --- prerequisites -----------------------------------------------------------
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
    Bad "Node.js not found on PATH."
    Info "Install Node 20+ from https://nodejs.org and re-run."
    return
}
$nodeMajor = [int](((& $node.Source --version) -replace '^v') -split '\.')[0]
if ($nodeMajor -lt 20) { Bad "Node 20+ required, found $(& $node.Source --version)"; return }

$build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
if ($build -lt 18309) { Bad "Windows 10 1809+ (build 18309) required for ConPTY, found build $build"; return }

Info "Channel:    $Channel"
Info "Install to: $InstallDir"
Info "Node:       $(& $node.Source --version)"
Write-Host ""

# --- find the release --------------------------------------------------------
Info "Finding $Channel release..."
try {
    if ($Channel -eq 'latest') {
        $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'session-broker-installer' }
    } else {
        $all = Invoke-RestMethod "https://api.github.com/repos/$repo/releases" -Headers @{ 'User-Agent' = 'session-broker-installer' }
        $release = $all | Where-Object { $_.prerelease } | Select-Object -First 1
        if (-not $release) { Bad "No prerelease found. Use -Channel latest."; return }
    }
} catch {
    Bad "Could not reach the releases API: $_"
    Info "Check https://github.com/$repo/releases"
    return
}

# The broker's asset, not the connect tool's: both end in win-x64.zip, and only
# the broker has a version number straight after the prefix.
$asset = $release.assets | Where-Object { $_.name -match '^caldwell-session-broker-\d.*-win-x64\.zip$' } | Select-Object -First 1
if (-not $asset) { Bad "No win-x64 asset in $($release.tag_name)."; return }

Good "Found $($release.tag_name)"
Info "Downloading $($asset.name)..."

$tmp = Join-Path $env:TEMP "session-broker-$($release.tag_name)"
$zip = "$tmp.zip"
Remove-Item $tmp, $zip -Recurse -Force -ErrorAction SilentlyContinue

try {
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
    Good "Downloaded ($([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB)"
} catch { Bad "Download failed: $_"; return }

# --- stop a running instance -------------------------------------------------
# Files are locked while the broker runs; the keep-alive trigger would also
# restart it mid-extract, so disable the task before touching anything.
$owner = (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1).OwningProcess
if ($owner) {
    Info "Stopping running broker (pid $owner)..."
    Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
    Stop-Process -Id $owner -Force
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 300
    }
}

# --- extract in place --------------------------------------------------------
# config.json, token.txt and logs\ are not in the archive, so extracting over an
# existing install leaves local state untouched.
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Info "Extracting to $InstallDir..."
Expand-Archive -Path $zip -DestinationPath $InstallDir -Force
Remove-Item $zip -Force -ErrorAction SilentlyContinue

# --- register and start ------------------------------------------------------
Info "Registering scheduled task..."
Push-Location (Join-Path $InstallDir 'broker')
try {
    & (Join-Path $InstallDir 'broker\install-task.ps1') -TaskName $TaskName | Out-Null
} finally { Pop-Location }

Enable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
Start-ScheduledTask -TaskName $TaskName
Info "Starting..."

$health = $null
$deadline = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    try { $health = Invoke-RestMethod "http://127.0.0.1:$Port/health" -TimeoutSec 3 } catch { }
    if ($health) { break }
}

Write-Host ""
if (-not $health) {
    Bad "No health response within 30s."
    Info "Check $InstallDir\broker\logs\broker.out.log"
    return
}

Write-Host "  ============================================================" -ForegroundColor Green
Good " INSTALLED - $($release.tag_name)"
Write-Host "  ============================================================" -ForegroundColor Green
Write-Host ""
Info "Location  : $InstallDir"
Info "Identity  : $($health.session_user)  elevated=$($health.elevated)  $($health.integrity_level)"
Info "Auth      : $($health.auth_mode)"
Info "Endpoint  : http://$($env:COMPUTERNAME):$Port"

# Distinguish "definitely not elevated" from "could not tell". /health now
# awaits its probes, so null should not happen - but a wedged probe times out
# and reports null, and warning "not elevated" about a broker that IS High
# integrity is worse than admitting we could not determine it.
if ($health.elevated -eq $false) {
    Write-Host ""
    Bad "WARNING: not elevated - admin operations will fail."
    Info "The task must use RunLevel Highest. Re-run this installer from an elevated prompt."
} elseif ($null -eq $health.elevated) {
    Write-Host ""
    Info "NOTE: could not determine elevation (probe did not report in time)."
    Info "      Check with: .\broker.ps1 status"
}

Write-Host ""
Info "Control   : cd $InstallDir\broker; .\broker.ps1 status"
Info "API       : curl http://127.0.0.1:$Port/help"

if ($health.auth_mode -eq 'off') {
    Write-Host ""
    Warn "Auth is OFF - anything that can reach port $Port runs as you with admin rights."
    Info "To enable a token:"
    Info "  [Convert]::ToBase64String((1..32|%{Get-Random -Max 256})) | Set-Content $InstallDir\broker\token.txt -NoNewline"
    Info "  '{`"port`":$Port,`"auth`":`"token`",`"bind`":`"auto`"}' | Set-Content $InstallDir\broker\config.json"
    Info "  cd $InstallDir\broker; .\broker.ps1 restart"
}
Write-Host ""
