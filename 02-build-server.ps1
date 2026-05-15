# Build stable-diffusion.cpp with optional CUDA / Vulkan / HIP (ROCm) support.
#
# sd.cpp requires a recursive clone (ggml is a submodule). Only one GPU backend
# can be active at a time — 01-configure.ps1 auto-probes for available toolchains
# and toggles SdCuda / SdVulkan / SdHipblas accordingly. Override by editing
# build\config-build.psd1 before running this script.

. "$PSScriptRoot\common.ps1"  # loads $cfg, adds ROCm to PATH
Enable-VsDevShell

# Clone stable-diffusion.cpp if missing, otherwise pull latest (recursive so
# the ggml submodule stays in sync).
if (-not (Test-Path "$($cfg.StableDiffusionCppDir)\CMakeLists.txt")) {
    Write-Host "stable-diffusion.cpp not found at $($cfg.StableDiffusionCppDir), cloning..." -ForegroundColor Yellow
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp $cfg.StableDiffusionCppDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
} else {
    Write-Host "Pulling latest stable-diffusion.cpp..." -ForegroundColor Cyan
    git -C $cfg.StableDiffusionCppDir pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw "git pull failed" }
    if (Test-Path "$($cfg.StableDiffusionCppDir)\.gitmodules") {
        git -C $cfg.StableDiffusionCppDir submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    }
}

$buildDir = Join-Path $PSScriptRoot "build\cmake-build"
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

# Validate: at most one GPU backend may be enabled. CUDA > Vulkan > HIP priority.
$enabled = @()
if ($cfg.SdCuda)    { $enabled += 'CUDA' }
if ($cfg.SdVulkan)  { $enabled += 'Vulkan' }
if ($cfg.SdHipblas) { $enabled += 'HIP' }
if ($enabled.Count -gt 1) {
    throw "Only one GPU backend may be enabled at a time. Currently enabled: $($enabled -join ', '). Edit build\config-build.psd1."
}

$cmakeArgs = @(
    "-S", $cfg.StableDiffusionCppDir
    "-B", $buildDir
    "-G", "Ninja"
    "-DCMAKE_BUILD_TYPE=$($cfg.BuildType)"
    "-DSD_BUILD_EXAMPLES=ON"
)

if ($cfg.SdCuda) {
    $cmakeArgs += '-DSD_CUDA=ON'
} elseif ($cfg.SdVulkan) {
    $cmakeArgs += '-DSD_VULKAN=ON'
} elseif ($cfg.SdHipblas) {
    $cmakeArgs += '-DSD_HIPBLAS=ON'
    if (Test-Path "$env:HIP_PATH\bin\clang.exe") {
        $cmakeArgs += "-DCMAKE_C_COMPILER=$env:HIP_PATH\bin\clang.exe"
        $cmakeArgs += "-DCMAKE_CXX_COMPILER=$env:HIP_PATH\bin\clang++.exe"
    }
}

Write-Host "Configuring..." -ForegroundColor Cyan
cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed" }

$buildArgs = @("--build", $buildDir, "--config", $cfg.BuildType)
if ($null -ne $env:NUMBER_OF_PROCESSORS) {
    $cores = [int]$env:NUMBER_OF_PROCESSORS
    if ($cores -gt 4) { $buildArgs += '-j', ([Math]::Min($cores, 16)) } else { $buildArgs += '-j' }
}

Write-Host "Building..." -ForegroundColor Cyan
cmake @buildArgs
if ($LASTEXITCODE -ne 0) { throw "CMake build failed" }

Write-Host "Build complete: $buildDir\bin\" -ForegroundColor Green
