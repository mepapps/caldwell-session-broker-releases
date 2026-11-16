<#
.SYNOPSIS
    Make this machine reachable through the session-broker relay with a PIN,
    for as long as this window stays open.

.DESCRIPTION
    Nothing is installed. The connect tool downloads to a temp folder, runs in
    this window, and is removed when it ends. Close the window or press Ctrl+C
    to end the session.

    Works in Windows PowerShell 5.1 and PowerShell 7. No admin rights needed to
    run it - but without them, admin commands sent to this machine will fail.

.EXAMPLE
    irm https://raw.githubusercontent.com/mepapps/caldwell-session-broker-releases/main/connect.ps1 | iex
#>
param(
    # A specific download - URL or local .zip. Default: the latest release.
    [string]$Asset
)

# Everything runs in a child scope so nothing (ErrorActionPreference included)
# leaks into the caller's session after the tool exits.
& {
    $ErrorActionPreference = 'Stop'
    # Windows PowerShell 5.1 redraws a progress bar per chunk, which makes a
    # large download many times slower than the network.
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $repo = 'mepapps/caldwell-session-broker-releases'

    # Leftovers from an earlier session whose cleanup never got to run. Only
    # folders a day old, so a session still running is never touched.
    Get-ChildItem $env:TEMP -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Name -like 'session-broker-connect-*' -or $_.Name -like 'session-broker-rt-*') -and
                       $_.LastWriteTime -lt (Get-Date).AddDays(-1) } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

    $from = $Asset
    if (-not $from) {
        Write-Host '  Finding the latest release...'
        $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'session-broker-connect' }
        $a = $release.assets | Where-Object { $_.name -like 'caldwell-session-broker-connect-*-win-x64.zip' } | Select-Object -First 1
        if (-not $a) { Write-Host "  No connect download in release $($release.tag_name)." -ForegroundColor Red; return }
        $from = $a.browser_download_url
    }

    $dir = Join-Path $env:TEMP ('session-broker-connect-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir | Out-Null
    try {
        $zip = Join-Path $dir 'connect.zip'
        Write-Host '  Downloading...'
        if ($from -match '^https?://') { Invoke-WebRequest $from -OutFile $zip -UseBasicParsing }
        else { Copy-Item -LiteralPath $from -Destination $zip }

        # ZipFile rather than Expand-Archive: same result, a fraction of the
        # time on Windows PowerShell 5.1.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
        Remove-Item -LiteralPath $zip -Force

        # Runs in THIS window, so the PIN appears right here. --ephemeral lets the
        # tool delete this folder itself if the window is closed instead of
        # Ctrl+C, when this script never gets to its finally block.
        & (Join-Path $dir 'session-broker-connect.exe') --ephemeral
    }
    finally {
        Start-Sleep -Milliseconds 500
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
