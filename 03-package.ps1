# Package stable-diffusion.cpp binaries into an NSIS installer.
# Prerequisites: a successful build (02-build.ps1) and NSIS installed.

. "$PSScriptRoot\common.ps1"           # loads $cfg, adds ROCm to PATH if applicable
Enable-VsDevShell                       # cmake --install needs the VS env

$ErrorActionPreference = 'Stop'

# ── Resolve version from git ───────────────────────────────────────────────

$srcDir   = $cfg.StableDiffusionCppDir
$origPos  = Get-Location
Push-Location "$srcDir" -ErrorAction SilentlyContinue | Out-Null
$version  = (git describe --tags 2>$null) -replace '^v', ''
if (-not $version) { $version = "0.0.0-$(git rev-parse --short HEAD 2>$null)" }
Pop-Location
Set-Location $origPos
Write-Host "Version: $version" -ForegroundColor Cyan

# ── Ensure NSIS is installed ────────────────────────────────────────────────

$nsisExe = $null
foreach ($p in @(
    "${env:ProgramFiles}\NSIS\makensis.exe"
    "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
)) {
    if (Test-Path $p) { $nsisExe = $p; break }
}

if (-not $nsisExe) {
    Write-Host "NSIS not found. Installing via winget..." -ForegroundColor Yellow
    winget install --id NSIS.NSIS --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "Failed to install NSIS" }
    foreach ($p in @(
        "${env:ProgramFiles}\NSIS\makensis.exe"
        "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
    )) {
        if (Test-Path $p) { $nsisExe = $p; break }
    }
    if (-not $nsisExe) { throw "NSIS installed but makensis.exe not found. Try restarting the shell." }
}
Write-Host "NSIS: $nsisExe" -ForegroundColor Cyan

# ── Stage files for the installer ───────────────────────────────────────────

$cmakeBuildDir = Join-Path $PSScriptRoot 'build\cmake-build'
$stageDir      = Join-Path $PSScriptRoot 'build\staging'
$outputDir     = Join-Path $PSScriptRoot 'dist'

if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir                -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir               -Force | Out-Null

# Find sd-cli.exe and sd-server.exe — they may be in several possible locations
function Get-Binary { param([string[]]$Paths) }
$sdcLiCandidates = @(
    "$cmakeBuildDir\bin\sd-cli.exe"                          # Ninja direct output
    "$cmakeBuildDir\Release\bin\sd-cli.exe"                  # MSVC release subdir
    "$cmakeBuildDir\x64\Release\sd-cli.exe"                  # older CMake layout
    Join-Path $cfg.StableDiffusionCppDir 'bin\sd-cli.exe'     # ninja install prefix
)

$sdServerCandidates = @(
    "$cmakeBuildDir\bin\sd-server.exe"
    "$cmakeBuildDir\Release\bin\sd-server.exe"
    "$cmakeBuildDir\x64\Release\sd-server.exe"
    Join-Path $cfg.StableDiffusionCppDir 'bin\sd-server.exe'
)

$sdcLi = $null; foreach ($c in $sdcLiCandidates)   { if (Test-Path $c) { $sdcLi  = $c; break } }
$server= $null; foreach ($c in $sdServerCandidates) { if (Test-Path $c) { $server = $c; break } }

if (-not $sdcLi) { throw "sd-cli.exe not found at any: $($sdcLiCandidates -join ', ')" }
Write-Host "Staging sd-cli... $(Split-Path $sdcLi -Leaf)" -ForegroundColor Cyan

# Create bin subfolder inside staging and copy the binaries.
$stageBin = Join-Path $stageDir 'bin'
New-Item -ItemType Directory -Path $stageBin -Force | Out-Null
Copy-Item "$sdcLi"  -Destination $stageBin -Force
if ($server)        { Copy-Item "$server" -Destination $stageBin -Force }

# Stage runtime scripts alongside the binaries.
Copy-Item "$PSScriptRoot\resources\run-generate.ps1"         -Destination $stageDir       -Force
Copy-Item "$PSScriptRoot\resources\config-model.ps1"         -Destination $stageDir       -Force
Copy-Item "$PSScriptRoot\resources\config-generate.ps1"      -Destination $stageDir       -Force
Copy-Item "$PSScriptRoot\resources\common-ini.ps1"           -Destination $stageDir       -Force

# ── Generate .nsi from template ─────────────────────────────────────────────

$templatePath = Join-Path $PSScriptRoot 'stable-diffusion-cpp.nsi.template'
$nsiPath      = Join-Path $PSScriptRoot 'build\stable-diffusion-cpp.nsi'
$installerName       = "stable-diffusion-cpp_${version}_x64-setup.exe"
$outputFile         = Join-Path $outputDir $installerName

$stageDirNfs   = $stageDir      -replace '/', '\'
$outputFileNfs = $outputFile    -replace '/', '\'

$nsiContent = (Get-Content $templatePath -Raw) `
    -replace '@VERSION@',      $version `
        -replace '@STAGING_DIR@',   $stageDirNfs `
        -replace '@OUTPUT_FILE@',   $outputFileNfs

Set-Content -Path $nsiPath -Value $nsiContent -Encoding UTF8
Write-Host "Generated: $nsiPath" -ForegroundColor Cyan

# ── Build installer ────────────────────────────────────────────────────────

Write-Host "Building installer..." -ForegroundColor Cyan
& $nsisExe $nsiPath
if ($LASTEXITCODE -ne 0) { throw "makensis failed (exit code $LASTEXITCODE)" }

# ── Cleanup transient files ────────────────────────────────────────────────

Remove-Item $nsiPath         -Force
Remove-Item $stageDir        -Recurse -Force

$size = [Math]::Round((Get-Item $outputFile).Length / 1MB, 1)
Write-Host ""
Write-Host "Installer created: $outputFile ($size MB)" -ForegroundColor Green
Write-Host ""
