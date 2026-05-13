# Auto-detect paths and generate/update config-build.psd1.
# Run this first to verify your environment is ready.
#
# config-build.psd1 holds build-time settings only (paths, GPU backend toggles).
# Runtime / per-model settings live under %LOCALAPPDATA%\stable-diffusion.cpp\config\
# and are written by resources\config-server.ps1 and resources\config-model.ps1
# on first launch (or via the NSIS install-time page).

param(
    [string]$StableDiffusionCppDir  # path to sd.cpp source. If omitted, defaults to .\build\stable-diffusion.cpp
)

# ── Detection functions ──────────────────────────────────────────────

function Find-VsDevShell {
    # Search known VS installation roots, newest first
    $roots = @(
        "${env:ProgramFiles}\Microsoft Visual Studio"
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio"
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $versions = Get-ChildItem $root -Directory | Sort-Object Name -Descending
        foreach ($ver in $versions) {
            $editions = @("Enterprise", "Professional", "Community", "BuildTools")
            foreach ($ed in $editions) {
                $script = Join-Path $ver.FullName "$ed\Common7\Tools\Launch-VsDevShell.ps1"
                if (Test-Path $script) { return $script }
            }
        }
    }
    # Fallback: vswhere
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -property installationPath 2>$null
        if ($installPath) {
            $script = Join-Path $installPath "Common7\Tools\Launch-VsDevShell.ps1"
            if (Test-Path $script) { return $script }
        }
    }
    return $null
}

function Find-ROCm {
    if ($env:HIP_PATH -and (Test-Path "$env:HIP_PATH\bin\hipcc.exe")) {
        return $env:HIP_PATH
    }
    $base = "${env:ProgramFiles}\AMD\ROCm"
    if (-not (Test-Path $base)) { return $null }
    $latest = Get-ChildItem $base -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest -and (Test-Path "$($latest.FullName)\bin")) {
        return $latest.FullName
    }
    return $null
}

function Find-VulkanSDK {
    if ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK)) { return $env:VULKAN_SDK }
    $glslc = Get-ChildItem "${env:ProgramFiles}\VulkanSDK\*\Bin\glslc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($glslc) { return (Split-Path (Split-Path $glslc.FullName)) }
    return $null
}

function Find-CacheDir {
    if ($env:SD_CACHE -and (Test-Path $env:SD_CACHE)) { return $env:SD_CACHE }
    $candidates = @(
        "E:\stable-diffusion.cpp\models"
        "D:\stable-diffusion.cpp\models"
        "$env:USERPROFILE\.cache\stable-diffusion.cpp"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Find-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Fallback: check HIP_PATH\bin (ROCm ships its own clang, cmake, etc.)
    if ($detected.HipPath) {
        $hipBin = Join-Path $detected.HipPath "bin\$Name.exe"
        if (Test-Path $hipBin) { return $hipBin }
    }
    return $null
}

# ── Run detection ────────────────────────────────────────────────────

Write-Host ""
Write-Host "  stable-diffusion.cpp-framework — Environment Check" -ForegroundColor Cyan
Write-Host "  ===================================================" -ForegroundColor Cyan
Write-Host ""

$detected = [ordered]@{}
$gaps     = @()

# --- Paths ---

$val = Find-VsDevShell
$detected.VsDevShell = $val
if ($val) { Write-Host "  [OK] VsDevShell     : $val" -ForegroundColor Green }
else      { Write-Host "  [!!] VsDevShell     : NOT FOUND" -ForegroundColor Red; $gaps += "VsDevShell — Install Visual Studio with C++ workload" }

# Activate VS Dev Shell early so tool detection (cmake, ninja) works
if ($val) {
    Write-Host ""
    Write-Host "  Activating VS Developer Shell..." -ForegroundColor DarkGray
    $prevDir = Get-Location
    & $val -Arch amd64
    Set-Location $prevDir
}

$val = Find-ROCm
$detected.HipPath = $val
if ($val) { Write-Host "  [OK] HipPath        : $val" -ForegroundColor Green }
else      { Write-Host "  [--] HipPath        : not found (optional, needed for ROCm/HIP)" -ForegroundColor Yellow }

# StableDiffusionCppDir (source clone): CLI param → default .\build\stable-diffusion.cpp
if (-not $StableDiffusionCppDir) {
    $StableDiffusionCppDir = "$PSScriptRoot\build\stable-diffusion.cpp"
}
$val = (Resolve-Path $StableDiffusionCppDir -ErrorAction SilentlyContinue)?.Path ?? $StableDiffusionCppDir
$detected.StableDiffusionCppDir = $val
Write-Host "  [OK] StableDiffusionCppDir : $val" -ForegroundColor Green

$val = Find-CacheDir
$detected.CacheDir = $val
if ($val) { Write-Host "  [OK] CacheDir       : $val" -ForegroundColor Green }
else      { Write-Host "  [--] CacheDir       : not found (will use default)" -ForegroundColor Yellow }

Write-Host ""

# --- Tools (detected AFTER VS Dev Shell activation) ---

Write-Host "  Tools" -ForegroundColor Cyan
Write-Host "  -----" -ForegroundColor Cyan

$tools = [ordered]@{
    cmake = "CMake — https://cmake.org/download/"
    ninja = "Ninja — winget install Ninja-build.Ninja"
    git   = "Git — https://git-scm.com/"
}

foreach ($tool in $tools.Keys) {
    $found = Find-Tool $tool
    if ($found) { Write-Host "  [OK] $($tool.PadRight(14)): $found" -ForegroundColor Green }
    else        { Write-Host "  [!!] $($tool.PadRight(14)): NOT FOUND" -ForegroundColor Red; $gaps += "$tool — $($tools[$tool])" }
}

# GPU backend probes (each one optional)
$nvcc = Find-Tool "nvcc"
if ($nvcc) { Write-Host "  [OK] nvcc (CUDA)    : $nvcc" -ForegroundColor Green }
else       { Write-Host "  [--] nvcc (CUDA)    : not found (optional, needed for CUDA)" -ForegroundColor Yellow }

$vulkanSdk = Find-VulkanSDK
if ($vulkanSdk) { Write-Host "  [OK] Vulkan SDK     : $vulkanSdk" -ForegroundColor Green }
else            { Write-Host "  [--] Vulkan SDK     : not found (optional, needed for Vulkan)" -ForegroundColor Yellow }

$hipcc = Find-Tool "hipcc"
if ($hipcc) { Write-Host "  [OK] hipcc (HIP)    : $hipcc" -ForegroundColor Green }
else        { Write-Host "  [--] hipcc (HIP)    : not found (optional, needed for ROCm/HIP)" -ForegroundColor Yellow }

Write-Host ""

# ── Summary ──────────────────────────────────────────────────────────

if ($gaps.Count -gt 0) {
    Write-Host "  Gaps found ($($gaps.Count)):" -ForegroundColor Red
    foreach ($g in $gaps) { Write-Host "    - $g" -ForegroundColor Red }
    Write-Host ""
} else {
    Write-Host "  All required dependencies found!" -ForegroundColor Green
    Write-Host ""
}

# ── Write config-build.psd1 ──────────────────────────────────────────

function Fmt($val) {
    if ($val -is [bool])   { if ($val) { return '$true' } else { return '$false' } }
    if ($val -is [int])    { return "$val" }
    if ($val -is [double]) { return "$val" }
    if ($val -is [string]) { return "'$($val -replace "'", "''" )'" }
    return "'$val'"
}

# Backend selection: at most one. Priority: CUDA > Vulkan > HIP.
$sdCuda    = [bool]$nvcc
$sdVulkan  = -not $sdCuda    -and ($null -ne $vulkanSdk)
$sdHipblas = -not $sdCuda    -and -not $sdVulkan -and ($null -ne $detected.HipPath)

$buildLines = [System.Collections.Generic.List[string]]::new()
$buildLines.Add('@{')
$buildLines.Add('    # Paths')
$buildLines.Add("    StableDiffusionCppDir = $(Fmt $detected.StableDiffusionCppDir)")
$buildLines.Add("    HipPath               = $(Fmt $detected.HipPath)")
$buildLines.Add("    VsDevShell            = $(Fmt $detected.VsDevShell)")
$buildLines.Add("    CacheDir              = $(Fmt $detected.CacheDir)")
$buildLines.Add('')
$buildLines.Add('    # GPU backends — auto-probed from available toolchains; only one active at a time.')
$buildLines.Add("    SdCuda                = $(Fmt $sdCuda)")
$buildLines.Add("    SdVulkan              = $(Fmt $sdVulkan)")
$buildLines.Add("    SdHipblas             = $(Fmt $sdHipblas)")
$buildLines.Add('')
$buildLines.Add('    # Build settings')
$buildLines.Add("    BuildType             = 'Release'")
$buildLines.Add('}')
$buildDir = Join-Path $PSScriptRoot 'build'
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
$buildLines | Set-Content -Path (Join-Path $buildDir 'config-build.psd1') -Encoding utf8NoBOM

Write-Host "  build\config-build.psd1 written." -ForegroundColor Green
Write-Host "  Runtime / per-model settings are written on first launch (or by the installer)." -ForegroundColor DarkGray
Write-Host ""
