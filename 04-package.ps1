# Package stable-diffusion.cpp binaries into an NSIS installer.
# Requires: a successful build (02-build-server.ps1) and NSIS.

. "$PSScriptRoot\common.ps1"  # loads $cfg, adds ROCm to PATH
Enable-VsDevShell             # convention: build/package scripts activate the VS env

$ErrorActionPreference = 'Stop'

# ── Resolve version: sd-config (harness) version + upstream sd.cpp tag ──
# The installer version leads with the sd-config crate version — this harness
# IS versioned by sd-config (it drives run-server.ps1 / mcp-server.ps1 and the
# GUI), so bumping sd-config\Cargo.toml is how we cut a harness release. The
# upstream stable-diffusion.cpp tag the binaries were built from is appended so
# the same harness over two different sd.cpp commits stays distinguishable:
#   <sd-config version>-<sd.cpp tag>     e.g. 1.0.0-master-685-19bdfe2
$cargoToml = Join-Path $PSScriptRoot 'sd-config\Cargo.toml'
$sdConfigVersion = $null
$inPackage = $false
foreach ($line in Get-Content $cargoToml) {
    if     ($line -match '^\s*\[package\]') { $inPackage = $true;  continue }
    elseif ($line -match '^\s*\[')          { $inPackage = $false; continue }
    if ($inPackage -and $line -match '^\s*version\s*=\s*"([^"]+)"') { $sdConfigVersion = $Matches[1].Trim(); break }
}
if (-not $sdConfigVersion) { throw "Could not read [package] version from $cargoToml" }

# Upstream sd.cpp tag (e.g. `master-685-19bdfe2`); fall back to the short SHA
# if the clone has no tags reachable.
Push-Location $cfg.StableDiffusionCppDir
$sdcppTag = (git describe --tags 2>$null) -replace '^v', ''
if (-not $sdcppTag) { $sdcppTag = (git rev-parse --short HEAD 2>$null) }
Pop-Location
$sdcppTag = "$sdcppTag".Trim()

$version = if ($sdcppTag) { "$sdConfigVersion-$sdcppTag" } else { $sdConfigVersion }
Write-Host "Version: $version" -ForegroundColor Cyan

# ── Ensure NSIS is installed ────────────────────────────────────────
$nsisExe = $null
$nsisSearchPaths = @(
    "${env:ProgramFiles}\NSIS\makensis.exe"
    "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
)
foreach ($p in $nsisSearchPaths) {
    if (Test-Path $p) { $nsisExe = $p; break }
}

if (-not $nsisExe) {
    Write-Host "NSIS not found. Installing via winget..." -ForegroundColor Yellow
    winget install --id NSIS.NSIS --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "Failed to install NSIS" }
    foreach ($p in $nsisSearchPaths) {
        if (Test-Path $p) { $nsisExe = $p; break }
    }
    if (-not $nsisExe) { throw "NSIS installed but makensis.exe not found. Try restarting the shell." }
}
Write-Host "NSIS: $nsisExe" -ForegroundColor Cyan

# ── Stage files ─────────────────────────────────────────────────────
$buildDir  = Join-Path $PSScriptRoot "build\cmake-build"
$stageDir  = Join-Path $PSScriptRoot "build\staging"
$outputDir = Join-Path $PSScriptRoot "dist"

if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir  -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Locate sd-cli.exe and sd-server.exe — Windows CMake puts binaries directly
# under bin\, but check Release/Debug fallbacks for robustness.
$binCandidates = @(
    "$buildDir\bin"
    "$buildDir\Release\bin"
    "$buildDir\Debug\bin"
)
$srcBin = $null
foreach ($c in $binCandidates) { if (Test-Path "$c\sd-server.exe") { $srcBin = $c; break } }
if (-not $srcBin) { throw "sd-server.exe not found under any of: $($binCandidates -join ', ')" }

Write-Host "Staging binaries from $srcBin" -ForegroundColor Cyan
$stageBin = Join-Path $stageDir 'bin'
New-Item -ItemType Directory -Path $stageBin -Force | Out-Null
# Copy everything in the build's bin\ directory (exe + ggml backend DLLs).
Copy-Item "$srcBin\*" -Destination $stageBin -Recurse -Force

# ── sd-config GUI/CLI binary ────────────────────────────────────────
# Always rebuild: cargo is a fast no-op when up to date, and an existence
# check alone would silently ship a binary that predates the current Rust /
# Slint sources. 03 throws on failure (EAP=Stop propagates it here).
$sdConfigExe = Join-Path $PSScriptRoot "sd-config\target\release\sd-config.exe"
Write-Host "Ensuring sd-config.exe is current — invoking 03-build-gui.ps1..." -ForegroundColor Cyan
& "$PSScriptRoot\03-build-gui.ps1"
if (-not (Test-Path $sdConfigExe)) { throw "sd-config.exe still missing after 03-build-gui.ps1: $sdConfigExe" }
Copy-Item $sdConfigExe -Destination $stageBin -Force
Write-Host "Staged sd-config.exe" -ForegroundColor Cyan

# Stage runtime scripts and icon. All staged flat in $stageDir — the NSIS
# template installs them into $INSTDIR side-by-side (configuration is done by
# bin\sd-config.exe, staged above).
Copy-Item "$PSScriptRoot\resources\run-server.ps1"          -Destination $stageDir -Force
Copy-Item "$PSScriptRoot\resources\common-functions.ps1"    -Destination $stageDir -Force
Copy-Item "$PSScriptRoot\resources\mcp-server.ps1"          -Destination $stageDir -Force
Copy-Item "$PSScriptRoot\resources\stable-diffusion.ico"    -Destination $stageDir -Force

# ── Generate .nsi from template ─────────────────────────────────────
$templatePath  = Join-Path $PSScriptRoot "stable-diffusion-cpp.nsi.template"
$nsiPath       = Join-Path $PSScriptRoot "build\stable-diffusion-cpp.nsi"
$installerName = "stable-diffusion-cpp-$version-win64-setup.exe"
$outputFile    = Join-Path $outputDir $installerName

$stageDirNsis   = $stageDir   -replace '/', '\'
$outputFileNsis = $outputFile -replace '/', '\'

# .Replace() (literal) instead of -replace (regex): a `$` in the staging /
# output path would otherwise be interpreted as a substitution group.
$nsiContent = (Get-Content $templatePath -Raw).
    Replace('@VERSION@',     $version).
    Replace('@STAGING_DIR@', $stageDirNsis).
    Replace('@OUTPUT_FILE@', $outputFileNsis)

Set-Content -Path $nsiPath -Value $nsiContent -Encoding UTF8
Write-Host "Generated: $nsiPath" -ForegroundColor Cyan

# ── Build installer ─────────────────────────────────────────────────
Write-Host "Building installer..." -ForegroundColor Cyan
& $nsisExe $nsiPath
if ($LASTEXITCODE -ne 0) { throw "makensis failed (exit code $LASTEXITCODE)" }

# ── Cleanup ─────────────────────────────────────────────────────────
Remove-Item $nsiPath -Force
Remove-Item $stageDir -Recurse -Force

$size = [math]::Round((Get-Item $outputFile).Length / 1MB, 1)
Write-Host ""
Write-Host "Installer created: $outputFile ($size MB)" -ForegroundColor Green
Write-Host ""
