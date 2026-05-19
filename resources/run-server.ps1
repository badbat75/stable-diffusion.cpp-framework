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
# presets.ini is the source of truth — hand-edit it freely; sd-config rewrites
# one section at a time while preserving the rest of the file.
#
# Unlike llama-server, sd-server loads ONE model set per process, so the
# launcher prompts the user to pick a preset when more than one is configured
# (or accepts `-Preset <id>` to skip the prompt).
#
# -ServerExe is an override for pointing at an alternate sd-server build
# (e.g. .\build\cmake-build\bin\sd-server.exe from an in-tree build).

[CmdletBinding()]
param(
    # Default resolves to HKLM:\Software\stable-diffusion.cpp\InstallDir\bin\
    # sd-server.exe (registry key written by the NSIS installer), falling back
    # to %ProgramFiles%\stable-diffusion.cpp\bin\sd-server.exe. Resolved lazily
    # in the body so $ServerExe-was-explicitly-passed is detectable.
    [string]$ServerExe,
    [string]$Preset,
    # Suppresses the "Press any key to close" prompts in the error trap and
    # failed-exit branch. mcp-server.ps1 passes this when spawning detached
    # (hidden window has no usable console for ReadKey).
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
trap {
    Write-Host "`n[X] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if (-not $NonInteractive) {
        Write-Host "`nPress any key to close..." -ForegroundColor DarkYellow
        $null = [System.Console]::ReadKey($true)
    }
    break
}

$installDir = $PSScriptRoot

. (Join-Path $installDir "common-functions.ps1")

$configDir   = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config"
$serverPath  = Join-Path $configDir "server.ini"
$presetsPath = Join-Path $configDir "presets.ini"
$runDir      = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\run"
$statePath   = Join-Path $runDir "sd-server.state"

# ── Single-instance guard ────────────────────────────────────────────
# mcp-server.ps1 (or any other consumer) reads $statePath to discover the
# running sd-server. Refuse to start if another instance is alive; silently
# clean up if the file is stale (PID gone).
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
if (Test-Path $statePath) {
    $existing = $null
    try { $existing = Get-Content -Path $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $existing = $null }
    if ($existing -and $existing.pid -and (Get-Process -Id $existing.pid -ErrorAction SilentlyContinue)) {
        throw "sd-server is already running (pid $($existing.pid), preset '$($existing.preset)', http://$($existing.host):$($existing.port)). Stop it before starting another instance."
    }
    Remove-Item $statePath -Force -ErrorAction SilentlyContinue
}

# ── server.ini ───────────────────────────────────────────────────────
if (-not (Test-Path $serverPath)) {
    $sdConfig = Join-Path $installDir "bin\sd-config.exe"
    if (-not (Test-Path $sdConfig)) {
        throw "server.ini missing and sd-config.exe not found at $sdConfig. Reinstall the package, or run 'sd-config server set ...' once cargo-built."
    }
    Write-Host "server.ini missing — launching sd-config (close it once configured)..." -ForegroundColor Cyan
    Start-Process -FilePath $sdConfig -Wait
    if (-not (Test-Path $serverPath)) { throw "server.ini was not created. Aborting." }
}
$srvRaw = Read-ServerIni -Path $serverPath

# ConvertTo-IntOrNull lives in common-functions.ps1.
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
    $sdConfig = Join-Path $installDir "bin\sd-config.exe"
    if (-not (Test-Path $sdConfig)) {
        throw "No presets configured and sd-config.exe not found. Reinstall the package."
    }
    Write-Host "No model presets found — launching sd-config (add one and close to continue)..." -ForegroundColor Cyan
    Start-Process -FilePath $sdConfig -Wait
    $hasPresets = (Test-Path $presetsPath) -and `
                  ([regex]::IsMatch((Get-Content -Path $presetsPath -Raw -Encoding UTF8), '(?m)^\['))
    if (-not $hasPresets) { throw "No model presets configured. Aborting." }
}

# ── Parse presets (Get-Presets lives in common-functions.ps1) ─────────
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
        # Show the model path regardless of whether the preset uses the
        # all-in-one bundle ('model' -> -m) or the split form
        # ('diffusion-model' -> --diffusion-model). Flag a genuinely missing
        # file so '<no model>' can't be mistaken for a detection failure.
        $model = '<no model>'
        foreach ($k in @('model', 'diffusion-model')) {
            if ($presets[$i].Keys.ContainsKey($k) -and $presets[$i].Keys[$k]) { $model = $presets[$i].Keys[$k]; break }
        }
        if ($model -ne '<no model>' -and -not (Test-Path -LiteralPath $model)) { $model = "$model  (FILE MISSING)" }
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
# Explicit -ServerExe is strict (caller intent). With no override, look up
# the NSIS-installer's registry entry, then %ProgramFiles%, picking the
# first candidate that actually exists.
if (-not $PSBoundParameters.ContainsKey('ServerExe')) {
    $candidates = @()
    try {
        $regInstall = (Get-ItemProperty -Path 'HKLM:\Software\stable-diffusion.cpp' -Name InstallDir -ErrorAction Stop).InstallDir
        if ($regInstall) { $candidates += (Join-Path $regInstall 'bin\sd-server.exe') }
    } catch {}
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles 'stable-diffusion.cpp\bin\sd-server.exe')
    }
    $ServerExe = ($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
    if (-not $ServerExe) {
        throw "sd-server.exe not found. Tried: $($candidates -join '; ')."
    }
}
if (-not (Test-Path -LiteralPath $ServerExe)) {
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

# sd-config writes either "localhost" (loopback-only) or a literal IP
# (0.0.0.0 for all interfaces, or a specific adapter address). Pass IPs
# through verbatim; only the "localhost" alias maps to 127.0.0.1.
$listenIp = if ($hostname -eq 'localhost') { '127.0.0.1' } else { $hostname }

$serverArgs = @(
    '--listen-ip',   $listenIp
    '--listen-port', $port
)

# Map preset keys (sd-config's presets.ini vocabulary) onto sd-server's CLI
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

# Use System.Diagnostics.Process (not the pipeline `& ... | Tee-Object`)
# so we get sd-server.exe's actual PID for the state file — consumers
# (mcp-server.ps1) can then Stop-Process directly without tree-kill.
# Output is captured via OutputDataReceived / ErrorDataReceived events
# and forwarded to both console and log; equivalent to the prior tee.
$psi = [System.Diagnostics.ProcessStartInfo]::new()
$psi.FileName = $ServerExe
foreach ($a in $serverArgs) { [void]$psi.ArgumentList.Add([string]$a) }
$psi.UseShellExecute        = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $false
# Pin sd-server's CWD to the per-user data dir. Without this, sd-server
# inherits whatever .NET Environment.CurrentDirectory was — which is NOT
# affected by PowerShell's Set-Location and, when run-server.ps1 is itself
# spawned via Start-Process -WindowStyle Hidden (mcp-server.ps1's
# switch_preset path), defaults to C:\Windows\System32. sd-server's
# refresh_lora_cache then recursively walks "." (the default
# --lora-model-dir) and hits Access-Denied entries inside System32, which
# bubbles up as HTTP 500 from /sdcpp/v1/capabilities AND /img_gen.
$psi.WorkingDirectory       = $dataDir

$proc = [System.Diagnostics.Process]::new()
$proc.StartInfo = $psi

# sd-server's progress bar prints with \r between updates and only emits \n
# at completion, so the line-buffered OutputDataReceived/BeginOutputReadLine
# path hides all interim progress until the final newline. Forward raw chunks
# from the underlying TextReader instead, on a real .NET thread (a PowerShell
# runspace can't service Task.Run without session state). Bytes hit the
# console and the log as soon as sd-server flushes its CRT buffer.
if (-not ('SdLogPipe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public static class SdLogPipe {
    private static readonly object _fileLock = new object();

    public static Task Forward(TextReader reader, string logPath, bool toStderr) {
        return Task.Run(() => {
            char[] buf = new char[4096];
            int n;
            try {
                while ((n = reader.Read(buf, 0, buf.Length)) > 0) {
                    string s = new string(buf, 0, n);
                    if (toStderr) { Console.Error.Write(s); } else { Console.Out.Write(s); }
                    try {
                        lock (_fileLock) {
                            File.AppendAllText(logPath, s, Encoding.UTF8);
                        }
                    } catch { }
                }
            } catch { }
        });
    }
}
'@
}

$outTask = $null
$errTask = $null
$stateWritten = $false
$exitCode = 0
try {
    if (-not $proc.Start()) { throw "Failed to start sd-server.exe." }
    $outTask = [SdLogPipe]::Forward($proc.StandardOutput, $logPath, $false)
    $errTask = [SdLogPipe]::Forward($proc.StandardError,  $logPath, $true)

    # State file is the contract with mcp-server: pid + host/port for
    # readiness probe + preset/server_exe for diagnostics.
    $state = [ordered]@{
        pid        = $proc.Id
        host       = $hostname
        port       = $port
        preset     = $active.Id
        server_exe = $ServerExe
        started_at = (Get-Date).ToString('o')
    }
    ($state | ConvertTo-Json) | Set-Content -Path $statePath -Encoding UTF8
    $stateWritten = $true

    $proc.WaitForExit()
    $exitCode = $proc.ExitCode
} finally {
    # Give the forwarder tasks a moment to drain any trailing buffered
    # bytes after sd-server exits before we fall through to cleanup.
    $drain = @($outTask, $errTask | Where-Object { $_ })
    if ($drain.Count -gt 0) { try { [System.Threading.Tasks.Task]::WaitAll($drain, 5000) | Out-Null } catch {} }
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch {} }
    if ($stateWritten) { Remove-Item $statePath -Force -ErrorAction SilentlyContinue }

    Write-Host ""
    if ($exitCode -eq 0) {
        Write-Host "[OK] Server stopped." -ForegroundColor Green
    } else {
        Write-Host "[X] sd-server exited with code $exitCode." -ForegroundColor Red
        Write-Host "    Last lines of $logPath" -ForegroundColor DarkGray
        Get-Content -Path $logPath -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if (-not $NonInteractive) {
            Write-Host ""
            Write-Host "Press any key to close..." -ForegroundColor DarkYellow
            $null = [System.Console]::ReadKey($true)
        }
    }
}
