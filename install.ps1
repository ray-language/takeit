# takeit installer for Windows. Downloads the prebuilt binary for this machine from the
# GitHub Release and installs it into a directory on your user PATH.
#
#   irm https://raw.githubusercontent.com/ray-language/takeit/master/install.ps1 | iex
#
# Environment variables (all optional):
#   TAKEIT_VERSION   tag to install (e.g. v0.4.0). Default: the latest release.
#   TAKEIT_BIN_DIR   install directory. Default: %LOCALAPPDATA%\Programs\takeit
#   TAKEIT_REPO      owner/repo. Default: ray-language/takeit
#   TAKEIT_NO_PATH   if set, do not add the install directory to the user PATH.
#   TAKEIT_DRY_RUN   if set, print the plan and download nothing (to test detection).
#
# Works on Windows PowerShell 5.1 and PowerShell 7. It never calls `exit`: run through
# `iex`, that would close the user's console.

& {
    $ErrorActionPreference = 'Stop'
    # Windows PowerShell 5.1 redraws its progress bar per chunk, which makes downloads
    # crawl; and it may not offer TLS 1.2, which GitHub requires.
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch { }

    function Info([string]$msg) { Write-Host "-> $msg" -ForegroundColor Cyan }
    function Note([string]$msg) { Write-Host "note: $msg" -ForegroundColor Yellow }

    $repo = if ($env:TAKEIT_REPO) { $env:TAKEIT_REPO } else { 'ray-language/takeit' }
    $binDir = if ($env:TAKEIT_BIN_DIR) { $env:TAKEIT_BIN_DIR } else {
        Join-Path $env:LOCALAPPDATA 'Programs\takeit'
    }

    try {
        # --- Detect the CPU -> Rust target triple ---------------------------------
        # The OS architecture, not this process's: an x64 PowerShell emulated on ARM64
        # reports AMD64 in PROCESSOR_ARCHITECTURE.
        $arch = $null
        try {
            $arch = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        } catch { }
        if (-not $arch) {
            $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else {
                $env:PROCESSOR_ARCHITECTURE
            }
        }
        $cpu = switch -Regex ($arch) {
            '^(X64|AMD64)$' { 'x86_64'; break }
            '^(Arm64|ARM64)$' { 'aarch64'; break }
            default { throw "unsupported architecture: $arch (takeit ships x86_64 and ARM64)" }
        }
        $target = "$cpu-pc-windows-msvc"
        $asset = "takeit-$target.zip"

        # --- Resolve the download URL ---------------------------------------------
        if ($env:TAKEIT_VERSION) {
            $base = "https://github.com/$repo/releases/download/$($env:TAKEIT_VERSION)"
            $version = $env:TAKEIT_VERSION
        } else {
            $base = "https://github.com/$repo/releases/latest/download"
            $version = 'latest'
        }
        $url = "$base/$asset"

        Info "takeit - $target - $version"
        Info "asset:   $asset"
        Info "target:  $binDir"
        if ($env:TAKEIT_DRY_RUN) {
            Info "DRY RUN - url: $url"
            return
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("takeit-install-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            # --- Download ----------------------------------------------------------
            Info 'downloading...'
            $zip = Join-Path $tmp $asset
            try {
                Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
            } catch {
                throw "could not download $url`n       is there a Release with that asset? See https://github.com/$repo/releases"
            }

            # --- Verify the checksum ----------------------------------------------
            $sumFile = "$zip.sha256"
            $haveSum = $true
            try {
                Invoke-WebRequest -Uri "$url.sha256" -OutFile $sumFile -UseBasicParsing
            } catch {
                $haveSum = $false
            }
            if ($haveSum) {
                $expected = ((Get-Content -Raw $sumFile).Trim() -split '\s+')[0].ToLower()
                $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
                if ($actual -ne $expected) {
                    throw "checksum mismatch for $asset`n       expected: $expected`n       actual:   $actual"
                }
                Info 'checksum ok'
            } else {
                Note 'the release publishes no .sha256 for this asset: checksum not verified'
            }

            # --- Extract and install ----------------------------------------------
            Info 'extracting...'
            $unpacked = Join-Path $tmp 'unpacked'
            Expand-Archive -Path $zip -DestinationPath $unpacked
            $exe = Join-Path $unpacked 'takeit.exe'
            if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
                throw "the package does not contain 'takeit.exe'"
            }
            New-Item -ItemType Directory -Force -Path $binDir | Out-Null
            $dest = Join-Path $binDir 'takeit.exe'
            try {
                Copy-Item -LiteralPath $exe -Destination $dest -Force
            } catch {
                throw "could not write $dest (is takeit running?): $($_.Exception.Message)"
            }
            # Drop the downloaded-from-the-internet mark, if any, so SmartScreen does not
            # stop the first run of an unsigned binary.
            Unblock-File -LiteralPath $dest -ErrorAction SilentlyContinue
            Info "installed: $dest"
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }

        # --- PATH ------------------------------------------------------------------
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @()
        if ($userPath) { $entries = $userPath -split ';' | Where-Object { $_ } }
        $onPath = $entries | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }
        if ($onPath) {
            Info "run 'takeit' from any directory"
        } elseif ($env:TAKEIT_NO_PATH) {
            Note "$binDir is not on your PATH (TAKEIT_NO_PATH is set)"
        } else {
            [Environment]::SetEnvironmentVariable('Path', (($entries + $binDir) -join ';'), 'User')
            $env:Path = "$env:Path;$binDir"
            Info "added $binDir to your user PATH (new terminals pick it up; this one already has it)"
        }
        Note "the sender listens for connections: the first 'takeit send' makes Windows Firewall ask to allow takeit"
    } catch {
        Write-Host "error: $($_.Exception.Message)" -ForegroundColor Red
    }
}
