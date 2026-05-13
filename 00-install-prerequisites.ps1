# Install & update the stable-diffusion.cpp build toolchain in one shot.
#
# winget packages (PowerShell 7+, NSIS) are installed if missing and
# upgraded if present, in a single self-elevated session. GPU SDKs (CUDA,
# Vulkan, HIP) are only probed and their install URLs printed.
#
# When build\config-build.psd1 + stable-diffusion.cpp clone exist, also runs
# `git pull --ff-only` on the source and flags a rebuild if the commit moved.
#
# Safe to run any time — idempotent.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WingetVersion {
    param([string]$Id)
    $output = winget list --id $Id --exact --accept-source-agreements 2>&1 | Out-String
    foreach ($line in ($output -split "`r?`n")) {
        if ($line.Contains($Id)) {
            $cols = $line -split '\s+'
            for ($i = 0; $i -lt $cols.Count; $i++) {
                if ($cols[$i] -eq $Id -and $i + 1 -lt $cols.Count) { return $cols[$i + 1].Trim() }
            }
        }
    }
    return $null
}

function Get-GitCommit {
    param([string]$RepoDir)
    if (-not $RepoDir -or -not (Test-Path "$RepoDir\.git")) { return $null }
    $sha = git -C $RepoDir rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $sha.Trim()
}

# ── Tracked packages and SDKs ───────────────────────────────────────

$wingetPackages = @(
    @{ Id = 'Microsoft.PowerShell' ; Name = 'PowerShell 7+' }
    @{ Id = 'NSIS.NSIS'            ; Name = 'NSIS' }
)

$manualSdks = @(
    @{ Name = 'CUDA Toolkit'      ; Url = 'https://developer.nvidia.com/cuda-downloads'
       Probe = { Test-Path "${env:ProgramFiles}\NVIDIA GPU Computing Toolkit\CUDA\*\bin\nvcc.exe" } }
    @{ Name = 'Vulkan SDK'        ; Url = 'https://vulkan.lunarg.com/sdk/home'
       Probe = { ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK)) -or (Test-Path "${env:ProgramFiles}\VulkanSDK\*\Bin\glslc.exe") } }
    @{ Name = 'AMD HIP SDK'       ; Url = 'https://www.amd.com/en/developer/resources/rocm-hub/hip-sdk.html'
       Probe = { Test-Path "${env:ProgramFiles}\AMD\ROCm\*\bin\hipcc.exe" } }
)

# ── Banner ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  stable-diffusion.cpp — Install & Update Toolchain" -ForegroundColor Cyan
Write-Host "  ===================================================" -ForegroundColor Cyan
Write-Host ""

# ── Capture pre-state ───────────────────────────────────────────────

Write-Host "Capturing current state..." -ForegroundColor DarkGray
$before  = @{}
$missing = @()
$present = @()
foreach ($p in $wingetPackages) {
    $v = Get-WingetVersion $p.Id
    $before[$p.Id] = $v
    if ($v) { $present += $p } else { $missing += $p }
}

$cfgPath = Join-Path $PSScriptRoot 'build\config-build.psd1'
$cfg     = if (Test-Path $cfgPath) { Import-PowerShellDataFile $cfgPath } else { $null }
$beforeSd = if ($cfg) { Get-GitCommit $cfg.StableDiffusionCppDir } else { $null }

foreach ($p in $wingetPackages) {
    $v = $before[$p.Id]
    if ($v) { Write-Host "  [OK] $($p.Name) $v" -ForegroundColor Green }
    else    { Write-Host "  [..] $($p.Name) not installed" -ForegroundColor Yellow }
}
foreach ($s in $manualSdks) {
    if (& $s.Probe) { Write-Host "  [OK] $($s.Name)" -ForegroundColor Green }
    else            { Write-Host "  [--] $($s.Name) not found (manual install)" -ForegroundColor Yellow }
}
Write-Host ""

# ── Build the elevated batch (winget install + upgrade) ─────────────

$wingetCommands = @()
foreach ($p in $missing) {
    $wingetCommands += "Write-Host 'Installing $($p.Name)...' -ForegroundColor Cyan"
    $wingetCommands += "winget install --id $($p.Id) --exact --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null"
}
foreach ($p in $present) {
    $wingetCommands += "Write-Host 'Upgrading $($p.Name)...' -ForegroundColor Cyan"
    $wingetCommands += "winget upgrade --id $($p.Id) --exact --silent --accept-source-agreements --accept-package-agreements 2>&1 | Out-Null"
}

if ($wingetCommands.Count -gt 0) {
    if (Test-IsAdmin) {
        & ([scriptblock]::Create($wingetCommands -join "`n"))
    } else {
        Write-Host "Requesting administrator privileges for winget..." -ForegroundColor Yellow
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wingetCommands -join "`n"))
        Start-Process powershell -Verb RunAs -Wait `
            -ArgumentList "-ExecutionPolicy Bypass -EncodedCommand $encoded" | Out-Null
    }
}

# ── Pull stable-diffusion.cpp source if cloned ──────────────────────

if ($cfg -and $beforeSd) {
    Write-Host ""
    Write-Host "Updating stable-diffusion.cpp..." -ForegroundColor Cyan
    git -C $cfg.StableDiffusionCppDir pull --ff-only
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  git pull failed in $($cfg.StableDiffusionCppDir)" -ForegroundColor Yellow
    }
}

# ── Capture post-state ──────────────────────────────────────────────

$after = @{}
foreach ($p in $wingetPackages) { $after[$p.Id] = Get-WingetVersion $p.Id }
$afterSd = if ($cfg) { Get-GitCommit $cfg.StableDiffusionCppDir } else { $null }

# ── Report ──────────────────────────────────────────────────────────

Write-Host ""
Write-Host "  Update Report" -ForegroundColor Cyan
Write-Host "  ====" -ForegroundColor Cyan
Write-Host ""

function Write-ReportRow {
    param([string]$Marker, [ConsoleColor]$Color, [string]$Name, [string]$Detail)
    Write-Host ("  {0} {1,-25} {2}" -f $Marker, $Name, $Detail) -ForegroundColor $Color
}

foreach ($p in $wingetPackages) {
    $b = $before[$p.Id]
    $a = $after[$p.Id]
    if      (-not $b -and $a)      { Write-ReportRow "[++]" Green    $p.Name "installed $a" }
    elseif  (-not $b -and -not $a) { Write-ReportRow "[!!]" Red      $p.Name "install failed" }
    elseif  ($b -and -not $a)      { Write-ReportRow "[!!]" Red      $p.Name "no longer detected" }
    elseif  ($b -ne $a)            { Write-ReportRow "[++]" Green    $p.Name "$b -> $a" }
    else                           { Write-ReportRow "[OK]" DarkGray $p.Name $a }
}

$rebuildSd = $false
if      (-not $beforeSd)              { Write-ReportRow "[--]" DarkGray "stable-diffusion.cpp" "(not cloned)" }
elseif  ($beforeSd -ne $afterSd)     { Write-ReportRow "[++]" Green    "stable-diffusion.cpp" "$beforeSd -> $afterSd"; $rebuildSd = $true }
else                                  { Write-ReportRow "[OK]" DarkGray "stable-diffusion.cpp" $beforeSd }

Write-Host ""
Write-Host "  Manual SDKs (not auto-updated):" -ForegroundColor DarkGray
foreach ($s in $manualSdks) {
    Write-Host ("    {0,-15} - {1}" -f $s.Name, $s.Url) -ForegroundColor DarkGray
}

# ── Recommendations ─────────────────────────────────────────────────

Write-Host ""
if (-not $cfg) {
    Write-Host "  Next: .\01-configure.ps1   # detect paths and generate config-build.psd1" -ForegroundColor Cyan
} elseif ($rebuildSd) {
    Write-Host "  Recommended actions:" -ForegroundColor Yellow
    Write-Host "    .\02-build.ps1              # stable-diffusion.cpp source updated" -ForegroundColor Yellow
    Write-Host "    .\03-package.ps1            # rebuild installer afterwards" -ForegroundColor Yellow
} else {
    Write-Host "  Toolchain up to date." -ForegroundColor Green
}
Write-Host ""
