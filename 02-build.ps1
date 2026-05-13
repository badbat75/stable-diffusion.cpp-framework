# Build stable-diffusion.cpp with optional CUDA + Vulkan + HIP support

. "$PSScriptRoot\common.ps1"   # loads $cfg, adds ROCm to PATH if applicable
Enable-VsDevShell

Write-Host ""

# ── Clone or update source ───────────────────────────────────────────────

$srcDir = $cfg.StableDiffusionCppDir
if (-not (Test-Path "$srcDir\CMakeLists.txt")) {
    Write-Host "Source not found at $srcDir, cloning..." -ForegroundColor Yellow
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp $srcDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
} else {
    Write-Host "Pulling latest stable-diffusion.cpp..." -ForegroundColor Cyan
    git -C $srcDir pull --ff-only
    # Update submodules if they exist.
    if (Test-Path "$srcDir\.gitmodules") {
        git -C $srcDir submodule update --init --recursive 2>$null | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "git pull failed" }
}

# ── CMake configure ────────────────────────────────────────────────────────

$buildDir = Join-Path $PSScriptRoot 'build\cmake-build'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

Write-Host "Configuring..." -ForegroundColor Cyan

$cmakeArgs = @(
    "-S", $srcDir
    "-B", $buildDir
    "-G", "Ninja"
    "-DCMAKE_BUILD_TYPE=$($cfg.BuildType)"
)

# GPU backend toggles — only one may be enabled; priority: CUDA > Vulkan > HIP
$backends = 0
if ($cfg.SD_CUDA)   { $backends++ }
if ($cfg.SD_VULKAN) { $backends++ }
if ($cfg.SD_HIPBLAS) { $backends++ }
if ($backends -gt 1) { throw "Only one GPU backend may be enabled at a time (CUDA, Vulkan, or HIP). Disable the others in build\config-build.psd1." }

if ($cfg.SD_CUDA)   { $cmakeArgs += "-DSD_CUDA=ON" }
else {
    if ($cfg.SD_VULKAN) { $cmakeArgs += "-DSD_VULKAN=ON" }
    else {
        if ($cfg.SD_HIPBLAS) {
            $cmakeArgs += '-DSD_HIPBLAS=ON'
            if (Test-Path "$env:HIP_PATH\bin\clang.exe") {
                $cmakeArgs += "-DCMAKE_C_COMPILER=$env:HIP_PATH\bin\clang.exe"
                $cmakeArgs += "-DCMAKE_CXX_COMPILER=$env:HIP_PATH\bin\clang++.exe"
            }
        }
    }
}

# Always build with examples (sd-cli and sd-server)
$cmakeArgs += '-DSD_BUILD_EXAMPLES=ON'

Write-Host "  CMake args:" -ForegroundColor DarkGray
foreach ($arg in $cmakeArgs) { Write-Host "    $arg" -ForegroundColor DarkGray }

cmake @cmakeArgs; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── Build ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Building..." -ForegroundColor Cyan

$buildArgs = @("--build", $buildDir, "--config", "$($cfg.BuildType)")
if ($null -ne $env:NUMBER_OF_PROCESSORS) {
    $cores   = [int]$env:NUMBER_OF_PROCESSORS
    if ($cores -gt 4) { $buildArgs += '-j', ([Math]::Min($cores, 16)) } else     { $buildArgs += '-j' }
}

cmake @buildArgs; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# ── Verify output ─────────────────────────────────────────────────────────

$binDir        = Join-Path $srcDir 'bin'
$sdcLiExe      = Get-Item "$buildDir\bin\sd-cli.exe" -ErrorAction SilentlyContinue
$sdServerExe   = Get-Item "$buildDir\bin\sd-server.exe" | Select-Object -First 1 -ErrorAction SilentlyContinue

# CMake's default output is often $srcDir (top-level build dir) with examples/bin/...
if (-not $sdcLiExe) {
    $altBinDir = Join-Path (Join-Path $buildDir 'Release') 'bin'
    $sdcLiExe      = Get-Item "$altBinDir\sd-cli.exe" -ErrorAction SilentlyContinue
}

$b   = if ($cfg.SD_CUDA) { '+CUDA' } else { '' }
$b  += if ($cfg.SD_VULKAN) { '+VK'  } else { '' }
$b  += if ($cfg.SD_HIPBLAS) { '+HIP' } else { '' }

Write-Host ""
if ($sdcLiExe -and (Test-Path $sdcLiExe.FullName)) {
    Write-Host "Build complete: sd-cli.exe found" -ForegroundColor Green
} else {
    Write-Host "Build complete. Binaries may be under: $buildDir\bin\ or $(Join-Path $buildDir 'Release')\\" -ForegroundColor Yellow
}
$null = if ($sdServerExe) { Write-Host "          sd-server.exe found" -ForegroundColor Green }
