# Interactive (or non-interactive) generator defaults config writer.
# Writes/updates %LOCALAPPDATA%\stable-diffusion.cpp\config\config.ini.
#
# Usage:
#   .\config-generate.ps1                  # interactive wizard
#   .\config-generate.ps1 -NonInteractive  # headless; also reads install-time args

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$configDir = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config"
$configIni = Join-Path $configDir "config.ini"

. (Join-Path $PSScriptRoot "common-ini.ps1")

# ── Read existing config (if any) ───────────────────────────────────

$currentDefaults = @{}
if (Test-Path $configIni) {
    $currentDefaults = Read-ConfigIni -Path $configIni
}

function ConvertTo-IntOrNull  { param($v); if ([string]::IsNullOrWhiteSpace("$v"))   { return $null }; $p=0; if ([int]::TryParse("$v", [ref]$p)) { return $p } else   { return $null } }
function ConvertTo-BoolOrNull { param($v) $s = "$v".Trim().ToLowerInvariant(); if ($s -in @('true','yes','on','1','$true')) { return $true }; if ($s -in @('false','no','off','0','$false')) { return $false }; return $null }

# ── Interactive wizard ─────────────────────────────────────────────

function Show-InteractiveConfig {
    Write-Host "  SD.cpp — Generation Defaults Configuration" -ForegroundColor Cyan
    Write-Host "  ==================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This configures default settings for sd-cli (the image generation tool)." -ForegroundColor DarkGray
    Write-Host "Per-model parameters (Prompt, Steps, CFG scale, etc.) are set per-model" -ForegroundColor DarkGray
    Write-Host "in models.ini via the 'Configure Model' Start Menu shortcut." -ForegroundColor DarkGray
    Write-Host ""

    $modelsFolder = $currentDefaults['ModelsFolder'] ?? "$env:USERPROFILE\.stable-diffusion.cpp\models"
    Write-Host "  Models directory:" -NoNewline
    Write-Host " [$modelsFolder]  (default: where your .gguf / .safetensors files live)" -ForegroundColor DarkGray

    $defaultPort = $currentDefaults['ServerPort'] ?? 7860
    Write-Host "  SD Server port:"   -NoNewline
    Write-Host " [$defaultPort]   (API endpoint for sd-server, or disable below)"      -ForegroundColor DarkGray

    Write-Host ""
    # Confirm save.
    $confirmed = Read-Host "Save these settings? [Y/n]"
    if ($confirmed -and $confirmed.ToLower() -ne 'y' -and $confirmed -ne '') {
        Write-Host "Configuration cancelled." -ForegroundColor Yellow
        return
    }

    # Collect values.
    $modelsFolder = Read-Host "Models directory (empty to skip)"
    if (-not $modelsFolder) { $modelsFolder = $currentDefaults['ModelsFolder'] ?? "$env:USERPROFILE\.stable-diffusion.cpp\models" }

    $serverPort      = Read-Host "SD Server port [$defaultPort]"
    if (-not $serverPort -or $serverPort -eq '') { $serverPort = $defaultPort; }
    elseif (-not [int]::TryParse($serverPort, [ref]$null)) { Write-Host "Invalid port number, using default." -ForegroundColor Yellow; $serverPort = $defaultPort }

    $enabledResponse = Read-Host "Enable sd-server on startup? [y/N]"
    $serverEnabled   = if ($enabledResponse -eq '' -or 'y' -contains $enabledResponse.ToLower()) { 'true' } else { 'false' }

    # Apply to config.ini.
    UpdateConfigInIni -ModelsFolder $modelsFolder -ServerPort ([int]$serverPort) -ServerEnabled $serverEnabled
    Write-Host "  Config saved to: $configIni" -ForegroundColor Green
}

function UpdateConfigInIni {
    param([string]$ModelsFolder, [int]$ServerPort, [string]$ServerEnabled)
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null

    Set-ConfigField   -Path $configIni -Key 'ModelsFolder'      -Value $ModelsFolder
    Set-ConfigField   -Path $configIni -Key 'DefaultModelName'  -Value ''
    Set-ConfigField   -Path $configIni -Key 'ServerPort'        -Value "$ServerPort"
    Set-ConfigField   -Path $configIni -Key 'ServerEnabled'     -Value $ServerEnabled
    Set-ConfigField   -Path $configIni -Key 'OutputDir'         -Value (Join-Path $env:USERPROFILE 'Pictures\sd-cpp-output')

    # Refresh server.ini's ModelsFolder pointer for sd-server.
    try { & (Join-Path $PSScriptRoot "config-generate.ps1") } catch {}
}

# ── Non-interactive mode (package install + CLI override) ────────────

if ($args -contains '-NonInteractive') {
    # Parse key-value args from the caller.
    $modelsFolder   = if ($args.IndexOf('-ModelsFolder') -ge 0)       { $args[$args.IndexOf('-ModelsFolder') + 1] } else     { '' }
    $serverPort     = if ($args.IndexOf('-ServerPort')    -ge 0)      { $args[$args.IndexOf('-ServerPort')    + 1] } else     { '7860'   }
    $serverEnabled  = if ($args.IndexOf('-ServerEnabled') -ge 0)      { $args[$args.IndexOf('-ServerEnabled') + 1] } else { 'true'  }
    $threads        = if ($args.IndexOf('-Threads')       -ge 0) { $args[$args.IndexOf('-Threads')       + 1] } else   { (Get-CimInstance Win32_ComputerSystem).NumberofLogicalProcessors / 2 }

    New-Item -ItemType Directory -Path $configDir -Force | Out-Null

    if (Test-Path $configIni) {
        # Preserve any existing ModelName.
        $existing = Read-ConfigIni -Path $configIni
        $modelName = $existing['DefaultModelName'] ?? 'auto'
    } else {
        $modelName = 'auto'
    }

    Set-ConfigField   -Path $configIni -Key 'ModelsFolder'      -Value ($modelsFolder ?? "$env:USERPROFILE\.stable-diffusion.cpp\models")
    Set-ConfigField   -Path $configIni -Key 'DefaultModelName'  -Value $modelName
    Set-ConfigField   -Path $configIni -Key 'ServerPort'        -Value "$serverPort"
    Set-ConfigField   -Path $configIni -Key 'ServerEnabled'     -Value ($serverEnabled ?? 'true')
    Set-ConfigField   -Path $configIni -Key 'OutputDir'         -Value (Join-Path $env:USERProfile 'Pictures\sd-cpp-output')
} elseif ($args -contains '-DumpIni') {
    # Dump current config as a portable INI for NSIS .onInit to ingest.
    if (-not (Test-Path $configIni)) {
        Write-Host "No existing config.ini found — writing defaults." -ForegroundColor DarkGray
        Set-ConfigField   -Path $configIni -Key 'ModelsFolder'      -Value "$env:USERPROFILE\.stable-diffusion.cpp\models"
        Set-ConfigField   -Path $configIni -Key 'ServerPort'        -Value '7860'
        Set-ConfigField   -Path $configIni -Key 'ServerEnabled'     -Value 'true'
        Set-ConfigField   -Path $configIni -Key 'OutputDir'         -Value (Join-Path $env:UserProfile 'Pictures\sd-cpp-output')
    }
    $dumpPath       = if ($args.IndexOf('-DumpIni') -ge 0) { $args[$args.IndexOf('-DumpIni') + 1] } else     { '$PLUGINSDIR\dumped.ini' }
    $currentDefaults = Get-Content -Path $configIni -Raw -Encoding UTF8 | ForEach-Object { $_ }

    # Copy config.ini content to dump path.
    if (Test-Path $configIni) { Copy-Item $configIni -Destination $dumpPath -Force } else      { Set-Content -Path $dumpPath -Value '[Settings]`r`nModelsFolder = auto' -Force }
    Write-Host "Dumped to: $dumpPath" -ForegroundColor DarkGray
} else {
   Show-InteractiveConfig
}
