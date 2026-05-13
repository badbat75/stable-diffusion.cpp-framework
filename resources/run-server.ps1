# Runtime entry point for the installed stable-diffusion.cpp distribution.
# Launched by the "stable-diffusion.cpp" Start Menu shortcut. Picks one preset
# from %LOCALAPPDATA%\stable-diffusion.cpp\config\presets.ini, translates it
# into sd-server CLI args, then launches sd-server. The user interacts with
# the built-in web UI at http://localhost:<port>/.
#
# Reads:
#   %LOCALAPPDATA%\stable-diffusion.cpp\config\server.ini    — machine-wide params
#   %LOCALAPPDATA%\stable-diffusion.cpp\config\presets.ini   — per-model presets
#
# presets.ini is the source of truth — hand-edit it freely; config-model.ps1
# updates one section at a time while preserving the rest of the file.
#
# Unlike llama-server, sd-server loads ONE model set per process, so the
# launcher prompts the user to pick a preset when more than one is configured
# (or accepts `-Preset <id>` to skip the prompt).
#
# -ServerExe is an override for pointing at an alternate sd-server build
# (e.g. .\build\cmake-build\bin\sd-server.exe from an in-tree build).

[CmdletBinding()]
param(
    [string]$ServerExe = (Join-Path $PSScriptRoot "bin\sd-server.exe"),
    [string]$Preset
)

$ErrorActionPreference = 'Stop'
trap {
    Write-Host "`n[X] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nPress any key to close..." -ForegroundColor DarkYellow
    $null = [System.Console]::ReadKey($true)
    break
}

$installDir = $PSScriptRoot

. (Join-Path $installDir "common-functions.ps1")

$configDir   = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config"
$serverPath  = Join-Path $configDir "server.ini"
$presetsPath = Join-Path $configDir "presets.ini"

# ── server.ini ───────────────────────────────────────────────────────
if (-not (Test-Path $serverPath)) {
    & (Join-Path $installDir "config-server.ps1")
    if (-not (Test-Path $serverPath)) { throw "server.ini was not created. Aborting." }
}
$srvRaw = Read-ServerIni -Path $serverPath

# Coerce strings → typed values.
function ConvertTo-IntOrNull  { param($v) if ([string]::IsNullOrWhiteSpace("$v")) { return $null }; $p=0; if ([int]::TryParse("$v", [ref]$p)) { return $p } else { return $null } }

$srv = @{
    Port      = ConvertTo-IntOrNull  $srvRaw['Port']
    Hostname  = $srvRaw['Hostname']
    Threads   = ConvertTo-IntOrNull  $srvRaw['Threads']
    ModelsDir = $srvRaw['ModelsDir']
}

# ── Need at least one configured preset ──────────────────────────────
$hasPresets = (Test-Path $presetsPath) -and `
              ([regex]::IsMatch((Get-Content -Path $presetsPath -Raw -Encoding UTF8), '(?m)^\['))
if (-not $hasPresets) {
    Write-Host "No model presets found — launching config-model.ps1..." -ForegroundColor Cyan
    & (Join-Path $installDir "config-model.ps1")
    $hasPresets = (Test-Path $presetsPath) -and `
                  ([regex]::IsMatch((Get-Content -Path $presetsPath -Raw -Encoding UTF8), '(?m)^\['))
    if (-not $hasPresets) { throw "No model presets configured. Aborting." }
}

# ── Parse presets ────────────────────────────────────────────────────
function Get-Presets {
    param([string]$Path)
    $text = Get-Content -Path $Path -Raw -Encoding UTF8
    $result = @()
    foreach ($m in [regex]::Matches($text, '(?m)^\[(?<id>[^\]\r\n]+)\][\s\S]*?(?=^\[|\z)')) {
        $keys = @{}
        foreach ($line in ($m.Value -split "(?:\r\n|\n)")) {
            $t = $line.Trim()
            if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#') -or $t.StartsWith('[')) { continue }
            if ($t -match '^([^=]+?)\s*=\s*(.*)$') {
                $val = $Matches[2].Trim()
                if ($val -match '^(.*?)\s+[;#]\s.*$') { $val = $Matches[1].Trim() }
                $keys[$Matches[1].Trim()] = $val
            }
        }
        $result += [pscustomobject]@{ Id = $m.Groups['id'].Value.Trim(); Keys = $keys }
    }
    return $result
}

$presets = @(Get-Presets -Path $presetsPath)

# ── Pick the preset ──────────────────────────────────────────────────
$active = $null
if ($Preset) {
    $active = $presets | Where-Object { $_.Id -eq $Preset } | Select-Object -First 1
    if (-not $active) { throw "Preset '$Preset' not found in $presetsPath." }
} elseif ($presets.Count -eq 1) {
    $active = $presets[0]
} else {
    Write-Host ""
    Write-Host "Available presets:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $model = if ($presets[$i].Keys.ContainsKey('model')) { $presets[$i].Keys['model'] } else { '<no model>' }
        Write-Host ("  [{0,2}] {1,-30}  {2}" -f ($i + 1), $presets[$i].Id, $model)
    }
    while (-not $active) {
        $reply = Read-Host "`nSelect preset [1-$($presets.Count)]"
        [int]$idx = 0
        if ([int]::TryParse($reply, [ref]$idx) -and $idx -ge 1 -and $idx -le $presets.Count) {
            $active = $presets[$idx - 1]
        } else {
            Write-Host "  Invalid selection." -ForegroundColor Yellow
        }
    }
}

# ── Locate sd-server ────────────────────────────────────────────────
if (-not (Test-Path $ServerExe)) {
    throw "sd-server.exe not found at $ServerExe."
}

# ── CWD to writable per-user dir ────────────────────────────────────
$dataDir = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp"
New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
Set-Location $dataDir

# ── Log file (tee'd from sd-server stdout+stderr) ───────────────────
$logsDir = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\logs"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
$logPath = Join-Path $logsDir "sd-server.log"
"=== Started $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -FilePath $logPath -Append -Encoding UTF8

# ── GPU info (OS-level — sd-server also prints this on startup) ──────
$gpuName = ''
$gpuVRAM = ''
try {
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        $smiOut = & $nvidiaSmi.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null
        if ($smiOut) {
            $parts = $smiOut.Trim().Split(',')
            $gpuName = $parts[0].Trim()
            $gpuVRAM = "{0} MiB" -f $parts[1].Trim()
        }
    }
    if (-not $gpuName) {
        $card = Get-CimInstance Win32_VideoController | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        if ($card) { $gpuName = $card.Name.Trim() }
    }
    if ($gpuName -and -not $gpuVRAM) {
        $card = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -eq $gpuName } | Select-Object -First 1
        if ($card -and $card.AdapterRAM) {
            $gpuVRAM = "{0} MiB" -f [Math]::Round($card.AdapterRAM / 1MB)
        }
    }
} catch {}

# ── Translate preset → sd-server CLI args ────────────────────────────
$hostname = if ($srv.Hostname)          { $srv.Hostname } else { 'localhost' }
$port     = if ($null -ne $srv.Port)    { $srv.Port }     else { 1234 }

$listenIp = if ($hostname -eq '0.0.0.0') { '0.0.0.0' } else { '127.0.0.1' }

$serverArgs = @(
    '--listen-ip',   $listenIp
    '--listen-port', $port
)

# Map preset keys (config-model.ps1's INI vocabulary) onto sd-server's CLI
# flags. Keys not present in $active.Keys are skipped; boolean-true keys
# become bare flags; everything else becomes `--key value`.
$keys = $active.Keys
function Add-StringArg { param([string]$Key, [string]$Flag) if ($keys.ContainsKey($Key) -and $keys[$Key]) { $script:serverArgs += $Flag, $keys[$Key] } }
function Add-BoolFlag  { param([string]$Key, [string]$Flag) if ($keys.ContainsKey($Key) -and $keys[$Key] -eq 'true') { $script:serverArgs += $Flag } }

Add-StringArg 'model'            '-m'
Add-StringArg 'diffusion-model'  '--diffusion-model'
Add-StringArg 'vae'              '--vae'
Add-StringArg 'llm'              '--llm'
Add-StringArg 't5xxl'            '--t5xxl'
Add-StringArg 'clip_l'           '--clip_l'
Add-StringArg 'clip_g'           '--clip_g'
Add-StringArg 'lora-model-dir'   '--lora-model-dir'
Add-StringArg 'embd-dir'         '--embd-dir'
Add-StringArg 'type'             '--type'
Add-StringArg 'max-vram'         '--max-vram'
Add-StringArg 'sampler'          '--sampling-method'
Add-StringArg 'steps'            '--steps'
Add-StringArg 'cfg-scale'        '--cfg-scale'
Add-StringArg 'guidance'         '--guidance'
Add-StringArg 'width'            '-W'
Add-StringArg 'height'           '-H'

Add-BoolFlag  'offload-to-cpu'   '--offload-to-cpu'
Add-BoolFlag  'mmap'             '--mmap'
Add-BoolFlag  'fa'               '--fa'
Add-BoolFlag  'diffusion-fa'     '--diffusion-fa'
Add-BoolFlag  'clip-on-cpu'      '--clip-on-cpu'
Add-BoolFlag  'vae-on-cpu'       '--vae-on-cpu'
Add-BoolFlag  'vae-tiling'       '--vae-tiling'

$threads = if ($null -ne $srv.Threads) { $srv.Threads } else { [Math]::Max(1, [Math]::Floor([Environment]::ProcessorCount * 0.5)) }
$serverArgs += '-t', $threads

# ── Banner ───────────────────────────────────────────────────────────
$verRaw = 'unknown'
try {
    $verOut = (& $ServerExe --help 2>&1) -join "`n"
    $verMatch = $verOut | Select-String 'version[:\s]+(\S+)' -ErrorAction SilentlyContinue
    if ($verMatch) { $verRaw = $verMatch.Matches[0].Groups[1].Value }
} catch {}
Write-Host ""

$BANNER_W = 80
$bannerRows = [System.Collections.ArrayList]@(
    ,@('stable-diffusion.cpp', "v$verRaw")
    ,@('Preset',  $active.Id)
    ,@('Presets', $presetsPath)
    ,@('Log',     $logPath)
)
if ($gpuName) { $bannerRows.Insert(0, @('GPU', "$gpuName  ($gpuVRAM)")) }

foreach ($r in $bannerRows) {
    $needed = 4 + 14 + $r[1].Length
    if ($needed -gt $BANNER_W) { $BANNER_W = $needed }
}

function Write-BannerRow { param([string]$Label, [string]$Value)
    $rowText = ("{0,-14}" -f $Label) + $Value
    $padding = " " * ($BANNER_W - 4 - $rowText.Length)
    Write-Host ("| $($rowText)$padding |") -ForegroundColor DarkGray
}

Write-Host ("+" + ("-" * ($BANNER_W - 2)) + "+") -ForegroundColor DarkGray
foreach ($r in $bannerRows) { Write-BannerRow $r[0] $r[1] }
Write-Host ("+" + ("-" * ($BANNER_W - 2)) + "+") -ForegroundColor DarkGray

# ── Launch info ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "[*] Starting sd-server..." -ForegroundColor Cyan
$urlHost = if ($hostname -eq '0.0.0.0') { [System.Net.Dns]::GetHostName() } else { $hostname }
Write-Host ("    url:        http://{0}:{1}" -f $urlHost, $port) -ForegroundColor Gray
Write-Host ("    command:    & `"$ServerExe`" $($serverArgs -join ' ')") -ForegroundColor Gray
Write-Host ("    threads:    {0}" -f $threads) -ForegroundColor Gray
Write-Host ("    preset:     {0}" -f $active.Id) -ForegroundColor Gray

# ── Launch server (foreground, Ctrl+C to stop) ──────────────────────
Write-Host ""
Write-Host "[*] Ctrl+C to stop" -ForegroundColor DarkYellow
Write-Host ""

$exitCode = 0
try {
    # Tee sd-server's stdout+stderr to both the console and the log so the
    # user can see what's happening AND we keep a persistent record. `2>&1`
    # merges stderr into stdout as plain strings (without this, $ErrorAction
    # = 'Stop' would turn every stderr line into a terminating error).
    & $ServerExe @serverArgs 2>&1 | Tee-Object -FilePath $logPath -Append
    $exitCode = $LASTEXITCODE
} finally {
    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "[OK] Server stopped." -ForegroundColor Green
    } else {
        Write-Host "[X] sd-server exited with code $exitCode." -ForegroundColor Red
        Write-Host "    Last lines of $logPath" -ForegroundColor DarkGray
        Get-Content -Path $logPath -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ""
        Write-Host "Press any key to close..." -ForegroundColor DarkYellow
        $null = [System.Console]::ReadKey($true)
    }
}
