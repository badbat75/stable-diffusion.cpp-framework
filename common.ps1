# Shared bootstrap for build/runtime scripts.
# Dot-source at the top of every script: . "$PSScriptRoot\common.ps1"
#
# - Loads $cfg from build\config-build.psd1 (build-time paths, GPU backends).
# - Adds ROCm/HIP\bin to PATH so HIP DLLs are loadable at both build and run time.
# - Exposes Enable-VsDevShell as a function; build scripts call it, runtime scripts don't.

$cfgPath = Join-Path $PSScriptRoot 'build\config-build.psd1'
if (-not (Test-Path $cfgPath)) {
    throw "build\config-build.psd1 not found. Run 01-configure.ps1 first."
}
$cfg = Import-PowerShellDataFile $cfgPath

if ($cfg.HipPath -and (Test-Path $cfg.HipPath)) {
    $env:HIP_PATH = $cfg.HipPath
    if ($env:PATH -notlike "*$($env:HIP_PATH)\bin*") {
        $env:PATH = "$env:HIP_PATH\bin;$env:PATH"
    }
}

function Enable-VsDevShell {
    if (-not $cfg.VsDevShell) {
        throw "VsDevShell not configured. Install Visual Studio with the C++ workload and re-run 01-configure.ps1."
    }
    if (-not (Test-Path $cfg.VsDevShell)) {
        throw "VsDevShell not found at '$($cfg.VsDevShell)'. Re-run 01-configure.ps1 to fix the path."
    }
    $prev = Get-Location
    & $cfg.VsDevShell -Arch amd64
    Set-Location $prev
}
