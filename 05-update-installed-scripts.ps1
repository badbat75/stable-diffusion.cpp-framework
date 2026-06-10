# Sync resources/ + sd-config.exe → installed stable-diffusion.cpp directory.
#
# Dev convenience: lets you iterate on the runtime PowerShell scripts and the
# sd-config GUI/CLI in this repo and push them straight into the NSIS-installed
# copy under Program Files without rebuilding the installer. sd-server.exe and
# the ggml backend DLLs are NOT touched — re-run 02-build-server.ps1 + the
# installer for those.
#
# sd-config.exe is taken as-is from sd-config\target\release\; if it's missing
# you'll get a [MISS] line — run 03-build-gui.ps1 first (or 04-package.ps1
# end-to-end).
#
# Resolves the target directory from HKLM\Software\stable-diffusion.cpp's
# InstallDir (set by the NSIS installer), falling back to
# %ProgramFiles%\stable-diffusion.cpp. Self-elevates via UAC since Program
# Files is admin-write only.
#
# Each file is hash-compared first; unchanged files are skipped.

[CmdletBinding()]
param(
    [string]$InstallDir = '',
    # Internal: set by the self-elevation relaunch below. Makes the elevated
    # session transcript its output to this file so the (non-elevated) caller
    # can print it — the elevated console window closes on exit.
    [string]$ElevatedLog = ''
)

$ErrorActionPreference = 'Stop'

# ── Resolve InstallDir ───────────────────────────────────────────────
if (-not $InstallDir) {
    try {
        $InstallDir = (Get-ItemProperty -Path 'HKLM:\Software\stable-diffusion.cpp' -Name InstallDir -ErrorAction Stop).InstallDir
    } catch {
        $InstallDir = Join-Path $env:ProgramFiles 'stable-diffusion.cpp'
    }
}
if (-not (Test-Path -LiteralPath $InstallDir)) {
    throw "InstallDir not found: $InstallDir  (run the NSIS installer first, or pass -InstallDir)"
}

# ── Self-elevate ─────────────────────────────────────────────────────
# Program Files is admin-write. If we're not elevated, relaunch with UAC
# and wait for the elevated pwsh to exit. The elevated session runs in its
# own console that closes on exit, so its output is INVISIBLE to the caller
# — it writes a transcript to a temp file which we print here afterwards
# (the classic failure is a locked bin\sd-config.exe while the GUI is open,
# which would otherwise just flash a window and report a bare exit code).
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Re-launching elevated to write into $InstallDir..." -ForegroundColor Yellow
    $elevLog = Join-Path ([IO.Path]::GetTempPath()) "sdcpp-05-update-$PID.log"
    # Start-Process -Verb RunAs goes through ShellExecute, which flattens
    # ArgumentList into one command-line string and splits on whitespace.
    # Quote paths explicitly so values with spaces (e.g. "Program Files")
    # survive as single tokens.
    $relaunchArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -InstallDir "{1}" -ElevatedLog "{2}"' -f `
        $MyInvocation.MyCommand.Path, $InstallDir, $elevLog
    try {
        $proc = Start-Process pwsh.exe -Verb RunAs -ArgumentList $relaunchArgs -PassThru -Wait
    } catch {
        Write-Host "Elevation declined — nothing copied." -ForegroundColor Yellow
        exit 1
    }
    if (Test-Path -LiteralPath $elevLog) {
        Get-Content -LiteralPath $elevLog | Write-Host
        Remove-Item -LiteralPath $elevLog -Force -ErrorAction SilentlyContinue
    }
    exit $proc.ExitCode
}

# Elevated session: mirror all host/error output to the caller's log file.
# The transcript is flushed live and auto-stopped at process exit, so even a
# terminating error (e.g. locked bin\sd-config.exe) lands in the file.
if ($ElevatedLog) {
    try { Start-Transcript -Path $ElevatedLog -Force | Out-Null } catch {}
}

# ── File list (mirrors 04-package.ps1 staging, minus the ggml DLLs) ──
# Each entry is { Src = absolute source path; Dst = path relative to InstallDir }.
$resources = Join-Path $PSScriptRoot 'resources'
$entries = @(
    [pscustomobject]@{ Src = Join-Path $resources 'run-server.ps1';                       Dst = 'run-server.ps1'       }
    [pscustomobject]@{ Src = Join-Path $resources 'common-functions.ps1';                 Dst = 'common-functions.ps1' }
    [pscustomobject]@{ Src = Join-Path $resources 'mcp-server.ps1';                       Dst = 'mcp-server.ps1'       }
    [pscustomobject]@{ Src = Join-Path $resources 'stable-diffusion.ico';                 Dst = 'stable-diffusion.ico' }
    [pscustomobject]@{ Src = Join-Path $PSScriptRoot 'sd-config\target\release\sd-config.exe'; Dst = 'bin\sd-config.exe' }
)

Write-Host ""
Write-Host "Target: $InstallDir"  -ForegroundColor Cyan
Write-Host ""

$updated = 0
$skipped = 0
$missing = 0
foreach ($entry in $entries) {
    $src = $entry.Src
    $dst = Join-Path $InstallDir $entry.Dst
    $label = $entry.Dst

    if (-not (Test-Path -LiteralPath $src)) {
        Write-Host ("  [MISS] {0}  (no source file at {1})" -f $label, $src) -ForegroundColor Red
        $missing++
        continue
    }

    $needsCopy = $true
    if (Test-Path -LiteralPath $dst) {
        $srcHash = (Get-FileHash -LiteralPath $src).Hash
        $dstHash = (Get-FileHash -LiteralPath $dst).Hash
        if ($srcHash -eq $dstHash) { $needsCopy = $false }
    }

    if (-not $needsCopy) {
        Write-Host ("  [ ok ] {0}" -f $label) -ForegroundColor DarkGray
        $skipped++
        continue
    }

    # Ensure parent directory exists (e.g. bin\ for sd-config.exe).
    $dstParent = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstParent)) {
        New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
    }

    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Host ("  [COPY] {0}" -f $label) -ForegroundColor Green
    $updated++
}

Write-Host ""
Write-Host ("Done: {0} updated, {1} unchanged, {2} missing." -f $updated, $skipped, $missing) -ForegroundColor Cyan
if ($missing -gt 0) { exit 1 }
