# Interactive wizard to add/edit per-model settings in models.ini.
# Saves parameters under a named section keyed by the model base filename (without .gguf/.safetensors).
#
# Usage:
#   .\config-model.ps1                    # interactive — pick existing model or enter new name
#   .\config-model.ps1 -ModelName "my-sd"  # direct edit of named section

[CmdletBinding()]
param([string]$ModelName)

$ErrorActionPreference = 'Stop'

$configDir     = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config"
$modelsIni     = Join-Path $configDir "models.ini"

. (Join-Path $PSScriptRoot "common-ini.ps1")

if ($ModelName) { Write-Host "--- Editing model: $ModelName ---" -ForegroundColor Cyan }

function Edit-ModelSection {
    param([string]$name)

    # Discover current models for default prompt list
    $modelsFolder = ""
    if (Test-Path (Join-Path $configDir "config.ini")) {
        . (Join-Path $PSScriptRoot "common-ini.ps1")
        $cfg = Read-ConfigIni -Path (Join-Path $configDir "config.ini")
        if ($cfg['ModelsFolder']) { $modelsFolder = $cfg['ModelsFolder'] }
    }

    function Get-SuggestedFiles {
        $files = @()
        foreach ($ext in @('*.gguf', '*.safetensors')) {
            if (Test-Path $modelsFolder) {
                foreach ($f in (Get-ChildItem -LiteralPath $modelsFolder -Filter $ext -ErrorAction SilentlyContinue)) {
                    $files += [PSCustomObject]@{ Name = $f.Name; Basename = $f.BaseName; Full = $f.FullName }
                }
            }
        }
        return $files | Sort-Object Basename
    }

    Write-Host ""
    Write-Host "--- Model Settings: $name ---" -ForegroundColor Cyan
    if ($modelsFolder) {
        Write-Host "  Scanning models folder: $modelsFolder" -ForegroundColor DarkGray
        $suggested   = Get-SuggestedFiles
        if ($suggested.Count -gt 0) {
            Write-Host ""
            Write-Host "  Known models:" -ForegroundColor DarkGray
            foreach ($i in 0..($suggested.Count - 1)) {
                Write-Host "    [$(($i+1).ToString())] $($suggested[$i].Basename) → $($suggested[$i].Name)" -ForegroundColor DarkGray
            }
        }
        $filePath    = Read-Host "  Model file path (full path to .gguf/.safetensors, or Enter for none)"
    } else {
        Write-Host ""
        Write-Host "  No models config found. Setting up fresh entry." -ForegroundColor DarkGray
        $filePath    = Read-Host "  Model file path (full path to .gguf/.safetensors)"
    }

    # Ask generation defaults for this model
    $prompt      = Read-Host "  Prompt (default positive prompt; can override on generate)"
    $negPrompt   = Read-Host "  Negative prompt"

    $v   = Read-Host "  Width [$($cfg['Width'] ?? 512)]"; if (-not $v) { $v = '512' }
    $width       = [int]$v
    $v   = Read-Host "  Height [$($cfg['Height'] ?? 512)]"; if (-not $v) { $v = '512' }
    $height      = [int]$v
    $v   = Read-Host "  Steps [$($cfg['Steps'] ?? 20)]"; if (-not $v) { $v = '20' }
    $steps       = [int]$v
    $v   = Read-Host "  CFG Scale [$($cfg['CFG'] ?? 7.5)]"; if (-not $v) { $v = '7.5' }
    $cfgScale    = [double]$v
    $smp   = Read-Host "  Sampling Method [k_euler]"; if (-not $smp) { $smp = 'k_euler' }
    $seedInput   = Read-Host "  Seed [-1 for random]"; if (-not $seedInput) { $seedInput = '-1' }
    if ($seedInput -notmatch '^\-?\d+$') { Write-Host "Invalid seed, using -1." -ForegroundColor Yellow; $seedInput = '-1' }

    $data        = @{
        'FilePath'     = if ($filePath) { $filePath } else { '(none)' }
        'Prompt'       = if ($prompt) { $prompt } else { '(none)' }
        'NegativePrompt'  =  if ($negPrompt) { $negPrompt } else { '(none)' }
        'Width'        = '$width'
        'Height'       = '$height'
        'Steps'        = '$steps'
        'CFG'          = '$cfgScale'
        'SampleMethod'    =   $smp
        'Seed'         =  '$seedInput'
    }

    if (-not (Test-Path (Split-Path -Parent $modelsIni))) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $modelsIni) -Force | Out-Null
    }

    Write-ModelSection -Path $modelsIni -SectionName $name -Data $data
    Write-Host "  Model config saved to: $modelsIni" -ForegroundColor Green
}

# Gather model name if not provided
if (-not $ModelName) {
    # List existing entries in models.ini
    $existingSections = @()
    if (Test-Path $modelsIni) {
        $content   = Get-Content -LiteralPath $modelsIni -Raw -Encoding UTF8
        $sectionRegex  = [regex]'\[(.+?)\]'
        foreach ($m in ($sectionRegex.Matches($content))) {
            $existingSections += $Matches[1].Trim()
        }
    }

    Write-Host ""
    Write-Host "Current models.ini entries:" -ForegroundColor Cyan
    if ($existingSections.Count -eq 0) {
        Write-Host "  (none)" -ForegroundColor DarkGray
    } else {
        foreach ($sec in $existingSections) {
            Write-Host "  [?] $sec" -ForegroundColor DarkGray
        }
    }

    $choice  = Read-Host "Select existing or type new section name"
    if ($existingSections.Count -ge 0 -and $existingSections.Count -le 9 -and "$choice" -match '^\d+$' -and [int]$choice -le $existingSections.Count) {
        $ModelName = $existingSections[[int]$choice - 1]
    } else {
        $ModelName = $choice
    }
    if (-not $ModelName) { Write-Host "No model name provided. Exiting." -ForegroundColor Yellow; exit 0 }
}

Edit-ModelSection -name $ModelName
