# Interactive script to scan for models and generate images via sd-cli.
# Writes the output PNG to the configured OutputDir in a timestamped subfolder.
#
# Usage:
#   .\run-generate.ps1               # interactive picker + prompt gathering
#   .\run-generate.ps1 -Auto         # uses DefaultModelName, skips model picker, prompts once for everything

[CmdletBinding()]
param([switch]$Auto)

$ErrorActionPreference = 'Stop'

$configDir     = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config"
$configIni     = Join-Path $configDir "config.ini"
$modelsIni     = Join-Path $configDir "models.ini"

. (Join-Path $PSScriptRoot "common-ini.ps1")

# Load config
if (-not (Test-Path $configIni)) {
    Write-Host "No config.ini found. Run config-generate.ps1 first." -ForegroundColor Red
    exit 1
}

$config = Read-ConfigIni -Path $configIni
$modelsFolder   = $config['ModelsFolder']        ?? "$env:USERPROFILE\.stable-diffusion.cpp\models"
$defaultModelName  = $config['DefaultModelName']     ?? 'auto'
$outputDir         = $config['OutputDir']            ?? "$env:USERPROFILE\Pictures\sd-cpp-output"

# Locate sd-cli
$basePath    = $PSScriptRoot -replace '\\resources$', ''
$sdc         = Get-Item "${basePath}\bin\sd-cli.exe" -ErrorAction SilentlyContinue
if (-not $sdc) {
    $altPath   = Join-Path $env:ProgramFiles "stable-diffusion.cpp\bin\sd-cli.exe"
    if (Test-Path $altPath) { $sdc = Get-Item $altPath }
}
if (-not $sdc) {
    # Development path
    $devCli    = Join-Path "$env:USERPROFILE\git\stable-diffusion.cpp" "build\cmake-build\bin\sd-cli.exe"
    if (Test-Path $devCli) { $sdc = Get-Item $devCli } else { $devCli = Join-Path "." "build\cmake-build\bin\sd-cli.exe"; if (Test-Path $devCli) { $sdc = Get-Item $devCli } }
}
if (-not $sdc) {
    Write-Host "sd-cli.exe not found. Install stable-diffusion.cpp or ensure it is built." -ForegroundColor Red
    exit 1
}

# Discover model files
function Get-AvailableModels {
    $models = @()
    foreach ($ext in @('*.gguf', '*.safetensors')) {
        if (-not (Test-Path $modelsFolder)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $modelsFolder -Filter $ext -ErrorAction SilentlyContinue)) {
            $sectionName   = $file.BaseName
            $iniEntry      = @{}
            if (Test-Path $modelsIni) {
                $iniEntry  = Read-ModelEntry -Path $modelsIni -SectionName $sectionName
            }
            $models += [PSCustomObject]@{
                Index       = $models.Count + 1
                Filename    = $file.Name
                Path        = $file.FullName
                SectionName = $sectionName
                HasConfig   = ($iniEntry.Count -gt 0)
            }
        }
    }
    return $models | Sort-Object Filename
}

$availableModels   = Get-AvailableModels
if ($availableModels.Count -eq 0) {
    Write-Host "No model files (.gguf, .safetensors) found in: $modelsFolder" -ForegroundColor Yellow
    Write-Host "Place your models there first."
    exit 1
}

# Select model
function Select-Model {
    Write-Host ""
    Write-Host "Available models:" -ForegroundColor Cyan
    foreach ($m in $availableModels) {
        Write-Host "  [$($m.Index)] $($m.Filename)" -NoNewline
        if ($m.HasConfig) { Write-Host " (configured)" -ForegroundColor DarkGray } else { Write-Host "" }
    }
    if ($Auto -and $defaultModelName -and $defaultModelName -ne 'auto') {
        $chosen      = $availableModels | Where-Object { $_.Filename -eq $defaultModelName }
        if ($chosen) { return $chosen }
    }

    # Auto-detect common model name patterns
    $defaultCandidates   = @('sd-v1-5', 'sd-v2-1', 'sdxl-turbo', 'v1-5-pruned', 'v2-1-stable-unstable')
    foreach ($name in $defaultCandidates) {
        $match       = $availableModels | Where-Object { $_.SectionName -like "*$name*" }
        if ($match) { return $match }
    }

    Write-Host ""
    $choice  = Read-Host "Select model number (1..$($availableModels.Count))"
    $idx     = [int]$choice - 1
    $chosen      = $availableModels[$idx]
    if (-not $chosen) {
        Write-Host "Invalid selection." -ForegroundColor Red
        Select-Model
    }
    return $chosen
}

$selectedModel   = Select-Model

# Load model defaults from models.ini
function Get-ModelDefaults {
    param([string]$SectionName)
    if (Test-Path $modelsIni) {
        return Read-ModelEntry -Path $modelsIni -SectionName $SectionName
    }
    return @{}
}

$modelDefaults  = Get-ModelDefaults -SectionName $selectedModel.SectionName

# Prompt helper
function Ask-Param {
    param([string]$Label, [string]$Current)
    Write-Host ""
    Write-Host "  ${Label}:" -ForegroundColor Cyan
    if ($null -eq $Current) { $display = '(none)' } else { $display = "$Current" }
    Write-Host "  Current: $display" -ForegroundColor DarkGray
    Write-Host "  Enter new value (Enter to keep):" -ForegroundColor DarkGray
    $input   = Read-Host ""
    if ($input) { return $input } else { return $Current }
}

$prompt     = Ask-Param -Label 'Prompt' -Current $modelDefaults['Prompt']
if (-not $prompt)         { $prompt       = '(no prompt)' }
$negPrompt   = ""
if (-not $Auto) {
    $negPrompt   = Ask-Param -Label 'Negative Prompt' -Current $modelDefaults['NegativePrompt']
} else {
    if ($modelDefaults.ContainsKey('NegativePrompt')) { $negPrompt = $modelDefaults['NegativePrompt'] }
    if (-not $negPrompt) { $negPrompt = '(none)' }
}

$DefaultHeight     = 512
$DefaultWidth      = 512
$DefaultSteps      = 20
$DefaultCfg        = 7.5

if (-not $Auto) {
    $v   = Read-Host "  Height [${modelDefaults['Height'] ?? $DefaultHeight}]"
    if ($v -and $v -match '^\d+$')       { $height       = [int]$v } else { $height      = $modelDefaults['Height']      ?? $DefaultHeight }
    $v   = Read-Host "  Width [${modelDefaults['Width'] ?? $DefaultWidth}]"
    if ($v -and $v -match '^\d+$')       { $width       = [int]$v } else { $width      = $modelDefaults['Width']       ?? $DefaultWidth }
    $v   = Read-Host "  Steps [${modelDefaults['Steps'] ?? $DefaultSteps}]"
    if ($v -and $v -match '^\d+$')       { $steps       = [int]$v } else { $steps      = $modelDefaults['Steps']       ?? $DefaultSteps }
    $v   = Read-Host "  CFG Scale [${modelDefaults['CFG'] ?? $DefaultCfg}]"
    if ($v -and $v -match '^\d+\.?\d*$') { $cfgScale   = [double]$v } else { $cfgScale    = $modelDefaults['CFG']       ?? $DefaultCfg }
    $smp  = Read-Host "  Sampling Method [${modelDefaults['SampleMethod'] ?? 'k_euler'}]"
    if ($smp)         { $sampleMethod   = $smp } else     { $sampleMethod     = 'k_euler' }
    $seedInput   = Read-Host "  Seed [-1 for random] [${modelDefaults['Seed']}]"
    if (-not $seedInput -or [string]::IsNullOrWhiteSpace($seedInput.Trim()))  {
        if ($modelDefaults.ContainsKey('Seed') -and $modelDefaults['Seed'] -match '^\d+$')  { $seed = [int]$modelDefaults['Seed'] } else { $seed = -1 }
    } else {
        if ($seedInput -match '^\-?\d+$') { $seed = [int]$seedInput } else { Write-Host "Invalid seed, using random." -ForegroundColor Yellow; $seed = -1 }
    }
} else {
    $height      = $modelDefaults['Height']       ?? $DefaultHeight
    $width       = $modelDefaults['Width']        ?? $DefaultWidth
    $steps       = $modelDefaults['Steps']        ?? $DefaultSteps
    $cfgScale    = $modelDefaults['CFG']          ?? $DefaultCfg
    if ($modelDefaults.ContainsKey('SampleMethod')) { $sampleMethod   = $modelDefaults['SampleMethod'] } else { $sampleMethod   = '' }
    if ($sampleMethod -notmatch '^\w')              { $sampleMethod     = 'k_euler' }
    if ($modelDefaults.ContainsKey('Seed') -and $modelDefaults['Seed'] -match '^\d+$')  { $seed = [int]$modelDefaults['Seed'] } else { $seed = -1 }
}

# Build sd-cli arguments
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
$timestamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionDir    = Join-Path $outputDir $timestamp
$outputPng     = Join-Path $sessionDir "${selectedModel.SectionName}_${timestamp}.png"

New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

Write-Host ""
Write-Host "--- Generating image with sd-cli ---" -ForegroundColor Green
Write-Host "  Model:    $($selectedModel.Filename)"
Write-Host "  Prompt:   $prompt"
Write-Host "  Steps:    $steps"
Write-Host "  Size:     ${width}x${height}"
Write-Host ""

$sdkCliArgs         = @(
    '-M', $selectedModel.Path,
    '-O', $outputPng,
    '--prompt', $prompt,
    '--width',  "$width",
    '--height', "$height",
    '--steps',  "$steps",
    '--cfg',    "$cfgScale"
)

if (-not [string]::IsNullOrWhiteSpace($sampleMethod))              { $sdkCliArgs += @('--sampler',     $sampleMethod) }
if ($seed -ne -1)                                                 { $sdkCliArgs += @('-n',      "$seed")       }
# Check sd-cli supports extra flags via --help
$sdkHelpCheck = & ${sdc.FullName} --help 2>&1 | Select-String '--batch-count' -SimpleMatch -ErrorAction SilentlyContinue
if ($sdkHelpCheck) { $sdkCliArgs += @('--batch-count', '1') }

Write-Host "Invoking: $($sdc.FullName) $($sdkCliArgs -join ' ')" -ForegroundColor DarkGray

try {
    & ${sdc.FullName} $sdkCliArgs
    if ($?) {
        Write-Host ""
        Write-Host "Image saved to: $outputPng" -ForegroundColor Green
        try { Invoke-Item $outputPng } catch {}
    } else  { Write-Host "sd-cli exited with an error." -ForegroundColor Red }
} catch {
    Write-Host "Failed to run sd-cli: $_" -ForegroundColor Red
}
