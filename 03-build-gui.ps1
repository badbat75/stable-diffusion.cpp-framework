# Build the sd-config GUI/CLI binary (Slint + Rust).
#
# Output: sd-config\target\release\sd-config.exe
#
# Prerequisites: a working `cargo` on PATH (rustup install stable). 04-package.ps1
# auto-invokes this before staging if the binary is missing or older than the
# Slint UI / Rust sources.

[CmdletBinding()]
param(
    # Run `cargo build` in debug mode instead of release.
    [switch]$Debug
)

$ErrorActionPreference = 'Stop'

$crateDir = Join-Path $PSScriptRoot 'sd-config'
if (-not (Test-Path $crateDir)) {
    throw "Crate directory not found: $crateDir"
}

# Verify cargo is on PATH.
$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $cargo) {
    Write-Host ""
    Write-Host "  cargo is not on PATH." -ForegroundColor Yellow
    Write-Host "  Install the Rust toolchain via 'winget install Rustlang.Rustup' then re-open the shell." -ForegroundColor Yellow
    Write-Host ""
    throw "cargo not found"
}

$profile = if ($Debug) { 'debug' } else { 'release' }
$profileFlag = if ($Debug) { @() } else { @('--release') }

Push-Location $crateDir
try {
    Write-Host "Building sd-config ($profile) in $crateDir..." -ForegroundColor Cyan
    & cargo build @profileFlag
    if ($LASTEXITCODE -ne 0) { throw "cargo build failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

$out = Join-Path $crateDir "target\$profile\sd-config.exe"
if (-not (Test-Path $out)) { throw "Build succeeded but binary is missing: $out" }

$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host ""
Write-Host "Built: $out ($size MB)" -ForegroundColor Green
Write-Host ""
Write-Host "Run it:" -ForegroundColor Cyan
Write-Host "  $out             # GUI"
Write-Host "  $out server show # CLI"
Write-Host "  $out --help"
Write-Host ""
