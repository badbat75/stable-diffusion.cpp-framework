# Package stable-diffusion.cpp binaries into an NSIS installer.
# Requires: a successful build (02-build-server.ps1) and NSIS.

. "$PSScriptRoot\common.ps1"  # loads $cfg, adds ROCm to PATH
Enable-VsDevShell             # cmake --install needs the VS env

$ErrorActionPreference = 'Stop'

# ── Resolve version from git ────────────────────────────────────────
Push-Location $cfg.StableDiffusionCppDir
$version = (git describe --tags 2>$null) -replace '^v', ''
if (-not $version) { $version = "0.0.0-$(git rev-parse --short HEAD)" }
Pop-Location
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
# Build it lazily if missing (mirrors how we treat sd-server.exe).
$sdConfigExe = Join-Path $PSScriptRoot "sd-config\target\release\sd-config.exe"
if (-not (Test-Path $sdConfigExe)) {
    Write-Host "sd-config.exe not built yet — invoking 03-build-gui.ps1..." -ForegroundColor Cyan
    & "$PSScriptRoot\03-build-gui.ps1"
    if ($LASTEXITCODE -ne 0) { throw "03-build-gui.ps1 failed (exit $LASTEXITCODE)" }
}
if (-not (Test-Path $sdConfigExe)) { throw "sd-config.exe still missing after 03-build-gui.ps1: $sdConfigExe" }
Copy-Item $sdConfigExe -Destination $stageBin -Force
Write-Host "Staged sd-config.exe" -ForegroundColor Cyan

# Stage runtime scripts and icon. All staged flat in $stageDir — NSIS template
# installs them into $INSTDIR side-by-side, and run-server.ps1 invokes the
# config writers via $installDir\config-*.ps1 (flat lookup, no subdir).
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

$nsiContent = (Get-Content $templatePath -Raw) `
    -replace '@VERSION@',     $version `
    -replace '@STAGING_DIR@', $stageDirNsis `
    -replace '@OUTPUT_FILE@', $outputFileNsis

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
