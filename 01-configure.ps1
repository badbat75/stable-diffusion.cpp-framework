# Auto-detect paths and generate/update config-build.psd1.
# Run this first to verify your environment is ready.
#
# config-build.psd1 holds build-time settings only (paths, GPU backend toggles).
# Runtime / per-model settings live under %LOCALAPPDATA%\stable-diffusion.cpp\config\
# and are written by resources\config-generate.ps1 and resources\config-model.ps1
# on first launch (or via the NSIS install-time page).

param(
    [string]$StableDiffusionCppDir   # path to source repo. If omitted, defaults to .\build\stable-diffusion.cpp
)

function Find-VsDevShell {
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

function Find-HipSDK {
    if ($env:HIP_PATH -and (Test-Path "$env:HIP_PATH\bin\hipcc.exe")) {
        return $env:HIP_PATH
    }
    $base = "${env:ProgramFiles}\AMD\ROCm"
    if (-not (Test-Path $base)) { return $null }
    $latest   = Get-ChildItem $base -Directory | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest -and (Test-Path "$($latest.FullName)\bin")) {
        return $latest.FullName
    }
    return $null
}

function Find-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($detected.HipPath) {
        $hipBin     = Join-Path $detected.HipPath "bin\$Name.exe"
        if (Test-Path $hipBin) { return $hipBin }
    }
    return $null
}

function Find-CacheDir {
    if ($env:SD_CACHE -and (Test-Path $env:SD_CACHE)) {
        return $env:SD_CACHE
    }
    # Use the output directory env var or user's Downloads as a common location
    $candidates = @(
        "$env:USERPROFILE\Downloads"
        "$env:USERPROFILE\.cache\stable-diffusion.cpp"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ── Run detection ────────────────────────────────────────────────────

Write-Host ""
Write-Host "  stable-diffusion.cpp — Environment Check" -ForegroundColor Cyan
Write-Host "  ==================================" -ForegroundColor Cyan
Write-Host ""

$detected   = [ordered]@{}
$gaps       = @()

# --- Paths ---

$val = Find-VsDevShell
$detected.VsDevShell          = $val
if ($val) { Write-Host "  [OK] VsDevShell     : $val" -ForegroundColor Green }
else      { Write-Host "  [!!] VsDevShell     : NOT FOUND" -ForegroundColor Red; $gaps += 'VsDevShell — Install Visual Studio with C++ workload' }

if ($val) {
    Write-Host ""
    Write-Host "  Activating VS Developer Shell..." -ForegroundColor DarkGray
    $prevDir = Get-Location
    & $val -Arch amd64
    Set-Location $prevDir
}

$val = Find-HipSDK
$detected.HipPath             = $val
if ($val) { Write-Host "  [OK] HipPath        : $val" -ForegroundColor Green }
else      { Write-Host "  [--] HipPath        : not found (optional, needed for ROCm/HIP)" -ForegroundColor Yellow }

# StableDiffusionCppDir: CLI param → default .\build\stable-diffusion.cpp
if (-not $StableDiffusionCppDir) {
    $StableDiffusionCppDir = "$PSScriptRoot\build\stable-diffusion.cpp"
}
$val   = (Resolve-Path $StableDiffusionCppDir -ErrorAction SilentlyContinue)?.Path ?? $StableDiffusionCppDir
$detected.StableDiffusionCppDir = $val
Write-Host "  [OK] StableDiffusionCppDir : $val" -ForegroundColor Green

$val   = Find-CacheDir
$detected.CacheDir           = $val
if ($val) { Write-Host "  [OK] CacheDir       : $val" -ForegroundColor Green }
else      { Write-Host "  [--] CacheDir       : not found (will use default env var)" -ForegroundColor Yellow }

Write-Host ""

# --- Tools ---

Write-Host "  Tools" -ForegroundColor Cyan
Write-Host "  -----" -ForegroundColor Cyan

$tools = [ordered]@{
    cmake   = 'CMake — https://cmake.org/download/'
    ninja   = 'Ninja — winget install Ninja-build.Ninja'
    git     = 'Git — https://git-scm.com/'
}

foreach ($tool in $tools.Keys) {
    $found       = Find-Tool $tool
    if ($found) { Write-Host "  [OK] $($tool.PadRight(14)): $found" -ForegroundColor Green }
    else        { Write-Host "  [!!] $($tool.PadRight(14)): NOT FOUND" -ForegroundColor Red; $gaps += "$tool — $($tools[$tool])" }
}

$nvcc = Find-Tool 'nvcc'
if ($nvcc) { Write-Host "  [OK] nvcc (CUDA)    : $nvcc" -ForegroundColor Green }
else       { Write-Host "  [--] nvcc (CUDA)    : not found (optional, needed for CUDA)" -ForegroundColor Yellow }

$hipccPath = Find-Tool 'hipcc'

$vulkanSdkPath = $null
if ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK)) {
    $vulkanSdkPath = $env:VULKAN_SDK
} else {
    $glslc = Get-ChildItem "${env:ProgramFiles}\VulkanSDK\*\Bin\glslc.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($glslc) {
        $vulkanSdkPath = Split-Path (Split-Path $glslc.FullName)
    }
}
if ($vulkanSdkPath) { Write-Host "  [OK] Vulkan SDK     : $vulkanSdkPath" -ForegroundColor Green }
else                { Write-Host "  [--] Vulkan SDK     : not found (optional, needed for Vulkan)" -ForegroundColor Yellow }

if ($hipccPath) { Write-Host "  [OK] hipcc (HIP)    : $hipccPath" -ForegroundColor Green }
else           { Write-Host "  [--] hipcc (HIP)    : not found (optional, needed for ROCm/HIP)" -ForegroundColor Yellow }

Write-Host ""

# ── Summary ──────────────────────────────────────────────────────────

if ($gaps.Count -gt 0) {
    Write-Host "  Gaps found ($($gaps.Count)):" -ForegroundColor Red
    foreach ($g in $gaps) {
        Write-Host "    - $g" -ForegroundColor Red
    }
    Write-Host ""
} else {
    Write-Host "  All required dependencies found!" -ForegroundColor Green
    Write-Host ""
}

# ── Write config-build.psd1 ──────────────────────────────────────────

function Fmt($val) {
    if ($val -is [bool])   { if ($val) { return '$true' } else { return '$false' } }
    if ($val -is [int])    { return "$val" }
    if ($val -is [double]) { return $val }
    if ($val -is [string]) { return "'$($val -replace "'", "''" )'" }
    return "'$val'"
}

function IsCMakeToolAvailable([string]$Name) {
    return (Get-Command $Name -ErrorAction SilentlyContinue) -ne $null
}

# Default CUDA/Vulkan/HIP on if their respective toolchain is present.
# Only one backend may be enabled — priority: CUDA > Vulkan > HIP.
$cudaOn       = ($nvcc -and $nvcc.Length -gt 0)
$vulkanOn     = -not $cudaOn -and $null -ne $vulkanSdkPath

$hipblason    = -not $cudaOn -and -not $vulkanOn
if (-not $hipblason -and $detected.HipPath -and (Test-Path "$detected.HipPath\bin\hipcc.exe")) {
    $hipblason = $true
}

$buildLines = [System.Collections.Generic.List[string]]::new()
$buildLines.Add('@{')
$buildLines.Add('    # Paths')
$buildLines.Add("    StableDiffusionCppDir  = $(Fmt $detected.StableDiffusionCppDir)")
$buildLines.Add("    VsDevShell             = $(Fmt $detected.VsDevShell)")
$buildLines.Add("    HipPath                = $(Fmt $detected.HipPath)")
$buildLines.Add('')
$buildLines.Add('    # Build settings (GPU backends — auto-probed from available toolchians)')
$buildLines.Add("    SD_CUDA                = $(if ($cudaOn) { '$true' } else { '$false' })")
$buildLines.Add("    SD_VULKAN              = $(Fmt $vulkanOn)")
$buildLines.Add("    SD_HIPBLAS             = $(if ($hipblason) { '$true' } else { '$false' })")
$buildLines.Add("    BuildType              = 'Release'")
$buildLines.Add('')
$buildLines.Add('    # Cache dir (model downloads, etc. — optional)')
$buildLines.Add("    CacheDir               = $(Fmt $detected.CacheDir)")
$buildLines.Add('}')

$pathToCreate      = Join-Path $PSScriptRoot 'build\config-build.psd1'
$dirOfConfig       = Split-Path -Parent $pathToCreate
New-Item -ItemType Directory -Path $dirOfConfig -Force | Out-Null
$buildLines        | Set-Content -Path $pathToCreate -Encoding utf8NoBOM

Write-Host "  config-build.psd1 written." -ForegroundColor Green
Write-Host "  Runtime / per-model settings are written on first launch (or by the installer)." -ForegroundColor DarkGray
Write-Host ""
