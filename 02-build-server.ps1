# Build stable-diffusion.cpp with optional CUDA / Vulkan / HIP (ROCm) support.
#
# sd.cpp requires a recursive clone (ggml is a submodule). Only one GPU backend
# can be active at a time — 01-configure.ps1 auto-probes for available toolchains
# and toggles SdCuda / SdVulkan / SdHipblas accordingly. Override by editing
# build\config-build.psd1 before running this script.

. "$PSScriptRoot\common.ps1"            # loads $cfg, adds ROCm to PATH
. "$PSScriptRoot\sdcpp-patches\patch-lib.ps1"  # Reset-SdCppClone / Invoke-SdCppPatches
Enable-VsDevShell

$patchRoot = Join-Path $PSScriptRoot 'sdcpp-patches'

# Upstream pin. Empty string = follow upstream HEAD. Non-empty = checkout that
# SHA after fetch instead of fast-forwarding. Used historically to dodge the
# ggml MATH_LIBRARY=NOTFOUND configure break on Windows (introduced upstream
# at caa823a); that break is now patched locally by the
# sdcpp-patches\ggml-math-library-win32 set, so HEAD is again the default.
# Re-pin here if you need to debug against a specific commit.
$sdcppPin = ''

# Clone stable-diffusion.cpp if missing, otherwise pull latest (recursive so
# the ggml submodule stays in sync). sdcpp-patches\ layers local source/wiring
# changes (HiDream-I1 transformer port, ggml MATH_LIBRARY Windows fix) on top:
# Reset-SdCppClone strips them BEFORE the pull so `--ff-only` always sees a
# clean tree, Invoke-SdCppPatches re-applies them AFTER the sync so every
# build is reproducible from the patch folder.
if (-not (Test-Path "$($cfg.StableDiffusionCppDir)\CMakeLists.txt")) {
    Write-Host "stable-diffusion.cpp not found at $($cfg.StableDiffusionCppDir), cloning..." -ForegroundColor Yellow
    git clone --recursive https://github.com/leejet/stable-diffusion.cpp $cfg.StableDiffusionCppDir
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    if ($sdcppPin) {
        Write-Host "Pinning stable-diffusion.cpp to $sdcppPin..." -ForegroundColor Yellow
        git -C $cfg.StableDiffusionCppDir checkout --quiet $sdcppPin
        if ($LASTEXITCODE -ne 0) { throw "git checkout $sdcppPin failed" }
        git -C $cfg.StableDiffusionCppDir submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    }
} else {
    Reset-SdCppClone -CloneDir $cfg.StableDiffusionCppDir -PatchRoot $patchRoot
    if ($sdcppPin) {
        Write-Host "Fetching stable-diffusion.cpp and pinning to $sdcppPin..." -ForegroundColor Cyan
        git -C $cfg.StableDiffusionCppDir fetch --tags origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
        git -C $cfg.StableDiffusionCppDir checkout --quiet --detach $sdcppPin
        if ($LASTEXITCODE -ne 0) { throw "git checkout $sdcppPin failed" }
    } else {
        # Use fetch + checkout master + pull rather than a bare `git pull`, so
        # the clone recovers cleanly even when a previous run (or a manual
        # debug session) left HEAD detached on a SHA.
        Write-Host "Fetching and fast-forwarding stable-diffusion.cpp master..." -ForegroundColor Cyan
        git -C $cfg.StableDiffusionCppDir fetch --tags origin
        if ($LASTEXITCODE -ne 0) { throw "git fetch failed" }
        git -C $cfg.StableDiffusionCppDir checkout --quiet master
        if ($LASTEXITCODE -ne 0) { throw "git checkout master failed" }
        git -C $cfg.StableDiffusionCppDir pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw "git pull failed" }
    }
    if (Test-Path "$($cfg.StableDiffusionCppDir)\.gitmodules") {
        git -C $cfg.StableDiffusionCppDir submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    }
}

Write-Host "Applying sdcpp-patches..." -ForegroundColor Cyan
Invoke-SdCppPatches -CloneDir $cfg.StableDiffusionCppDir -PatchRoot $patchRoot

$buildDir = Join-Path $PSScriptRoot "build\cmake-build"
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null

# ── sccache: use local cache if available ─────────────────────────
# Optional compiler cache. When sccache.exe is on PATH we wire it up as a
# CMake compiler launcher for C/CXX/CUDA — incremental rebuilds across clean
# wipes get an ~order-of-magnitude speedup on the heavy CUDA TUs. Disabled
# silently when sccache isn't installed (recommended: `winget install
# Mozilla.sccache`). Mirrors the wiring in llama.cpp-framework\02-build.ps1.
$sccachePath = Get-Command sccache -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if ($sccachePath) {
    $sccacheDir = Join-Path $PSScriptRoot "build\.sccache"
    New-Item -ItemType Directory -Path $sccacheDir -Force | Out-Null
    $env:SCCACHE_DIR = $sccacheDir
    $env:SCCACHE_CACHE_SIZE = "10G"
    $env:SCCACHE_IDLE_TIMEOUT = "0"
    $env:SCCACHE_MAX_FRAME_LENGTH = "104857600"  # 100MB — GPU multi-arch objects are large
    Write-Host "sccache: $sccachePath (cache: $sccacheDir)" -ForegroundColor Cyan
} else {
    Write-Host "sccache not found — building without compiler cache" -ForegroundColor DarkGray
}

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
    # NOTE: -DSD_HIDREAM_I1_EXPERIMENTAL=ON was dropped 2026-06-09 along with
    # disabling the sdcpp-patches\hidream-i1 set (see its .disabled marker).
    # The build now follows vanilla upstream, which natively supports Ideogram4
    # (leejet/stable-diffusion.cpp#1609). Re-add the flag here AND drop the
    # patch's .disabled marker if you ever want to rebuild the HiDream-I1 port.
)

if ($cfg.SdCuda) {
    $cmakeArgs += '-DSD_CUDA=ON'
    # Do NOT pin nvcc's host compiler via -DCMAKE_CUDA_HOST_COMPILER.
    # CUDA 13.x's nvcc string-compares the cl.exe it finds in PATH against the
    # -ccbin value and aborts when they differ. CMake emits -ccbin in 8.3 SHORT
    # form (the MSVC toolset path contains spaces) while Enable-VsDevShell puts
    # the LONG-form cl.exe first on PATH, so pinning -ccbin self-conflicts:
    #   nvcc fatal : cl.exe in PATH (...\14.51.36231\...) is different than one
    #                specified with -ccbin (...\1451~1.362\...)
    # Enable-VsDevShell already guarantees the correct cl.exe is first on PATH,
    # so leave -ccbin unset and let nvcc discover it. If a polluted parent shell
    # ever shadows cl.exe, re-run this script from a fresh terminal (which is
    # what the build harness does anyway).
} elseif ($cfg.SdVulkan) {
    $cmakeArgs += '-DSD_VULKAN=ON'
} elseif ($cfg.SdHipblas) {
    $cmakeArgs += '-DSD_HIPBLAS=ON'
    if (Test-Path "$env:HIP_PATH\bin\clang.exe") {
        $cmakeArgs += "-DCMAKE_C_COMPILER=$env:HIP_PATH\bin\clang.exe"
        $cmakeArgs += "-DCMAKE_CXX_COMPILER=$env:HIP_PATH\bin\clang++.exe"
    }
}

if ($sccachePath) {
    # sccache wraps MSVC cl.exe (C/CXX) reliably, so cache those TUs.
    $cmakeArgs += "-DCMAKE_C_COMPILER_LAUNCHER=$sccachePath"
    $cmakeArgs += "-DCMAKE_CXX_COMPILER_LAUNCHER=$sccachePath"
    # Do NOT wrap nvcc with sccache. sccache 0.15.0 mishandles nvcc's
    # multi-phase compilation under CUDA 13.x: the per-arch .cubin that one
    # nvcc sub-step emits isn't where the following `fatbinary` step looks for
    # it, so every CUDA TU dies with:
    #   fatbinary fatal : Could not open input file 'add-id.cubin'
    # Until sccache's nvcc support catches up, compile CUDA TUs directly.
    # (If sccache is NOT installed the build already runs uncached — same path.)
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

if ($sccachePath) {
    Write-Host ""
    Write-Host "sccache stats:" -ForegroundColor Cyan
    sccache --show-stats
    sccache --stop-server 2>$null | Out-Null
}

Write-Host "Build complete: $buildDir\bin\" -ForegroundColor Green
