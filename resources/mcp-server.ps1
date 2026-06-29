# MCP server for stable-diffusion.cpp (PowerShell, stdio transport).
# Bridges Claude Code (or any MCP client) to a running sd-server instance.
#
# Protocol: JSON-RPC 2.0, newline-delimited, over stdin/stdout.
# All diagnostic logging goes to stderr + a log file — never stdout, which
# is reserved for the JSON-RPC stream.
#
# Reads sd-server's host/port from
#   %LOCALAPPDATA%\stable-diffusion.cpp\config\server.ini
# Lifecycle (switch_preset / start) is driven through run-server.ps1, which
# writes %LOCALAPPDATA%\stable-diffusion.cpp\run\sd-server.state — this script
# reads that file to learn the live pid/host/port/preset.
#
# Tools exposed:
#   generate_image     — txt2img / img2img via /sdcpp/v1/img_gen; async
#                        (fire-and-forget) by default, wait=true to block.
#                        A save_path job also spawns a detached background
#                        collector (this script, -CollectJob <id>) that saves
#                        the result to disk on completion, so it survives even
#                        if the client never polls — sd-server drops a completed
#                        result after 600s (completed_ttl_seconds).
#   check_image_job    — poll an async job by id; deliver the image when done
#   cancel_image_job   — cancel a queued/running async job by id
#   encode_file_base64 — read a local file, return base64 (debug aid)
#   get_model_info     — curated /sdcpp/v1/capabilities snapshot
#   server_status      — is sd-server alive and ready to serve?
#   list_presets       — enumerate presets.ini, mark the active one
#   switch_preset      — stop + restart sd-server with a different preset
#   stop_server        — Stop-Process the running sd-server (if any)
#
# Wire it into Claude Code via ~/.claude.json or a project .mcp.json:
#   {
#     "mcpServers": {
#       "stable-diffusion-cpp": {
#         "command": "pwsh.exe",
#         "args": ["-NoProfile", "-ExecutionPolicy", "Bypass",
#                  "-File", "C:\\Program Files\\stable-diffusion.cpp\\mcp-server.ps1"]
#       }
#     }
#   }
#
# Generated images are returned inline as MCP image content (base64) only —
# no on-disk copy, matching the built-in web UI's behaviour. The image bytes
# are passed through verbatim from sd-server's b64_json field — no decode /
# re-encode in this script.

[CmdletBinding()]
param(
    [string]$ServerIni        = (Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config\server.ini"),
    [string]$LogPath          = (Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\logs\mcp-server.log"),
    [int]   $PollIntervalMs   = 500,
    [int]   $RequestTimeoutSec = 600,
    # Background-collector mode. When -CollectJob is set this process does NOT
    # run the MCP stdio loop: it polls that one async job to completion and
    # persists the result to disk via Complete-ImageJob, immune to sd-server's
    # 600s completed-result TTL, then exits. Spawned detached by the
    # fire-and-forget generate_image path for save_path jobs (Start-CollectorProcess).
    [string]$CollectJob       = '',
    [int]   $CollectPollSec   = 15,
    [int]   $CollectMaxSec    = 21600
)

$ErrorActionPreference = 'Stop'

# Version reported to MCP clients in the initialize handshake. Keep in lockstep
# with sd-config\Cargo.toml's [package] version (it leads the installer version).
$script:McpServerVersion = '1.0.0'

. (Join-Path $PSScriptRoot "common-functions.ps1")

# ── Logging ──────────────────────────────────────────────────────────
New-Item -ItemType Directory -Path (Split-Path $LogPath -Parent) -Force | Out-Null
function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    [Console]::Error.WriteLine($line)
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}

# ── sd-server endpoint ───────────────────────────────────────────────
# Two layers of resolution:
#   1. Preferred: run\sd-server.state, written by run-server.ps1 when it
#      spawns sd-server. Authoritative — reflects the actual host/port the
#      live process bound to, even if server.ini was edited afterwards.
#   2. Fallback: server.ini, captured here at startup. Used when no state
#      file is present (e.g. someone ran sd-server.exe by hand, bypassing
#      run-server.ps1) or when the state file's pid is no longer alive.
# Get-SdServerBaseUrl is called on every Invoke-SdJson so switch_preset
# (and any port change) is picked up without restarting mcp-server.
$srvRaw  = Read-ServerIni -Path $ServerIni
$srvHost = if ($srvRaw['Hostname']) { $srvRaw['Hostname'] } else { 'localhost' }
# ConvertTo-IntOrNull instead of a [int] cast: with EAP=Stop a non-numeric
# Port in a hand-edited server.ini would kill the whole MCP server at startup.
$srvPort = ConvertTo-IntOrNull $srvRaw['Port']
if ($null -eq $srvPort) { $srvPort = 1234 }
if ($srvHost -eq '0.0.0.0') { $srvHost = '127.0.0.1' }
$baseUrlFallback = "http://${srvHost}:${srvPort}"
Write-Log INFO "sd-server fallback endpoint: $baseUrlFallback  (config: $ServerIni)"

function Get-SdServerBaseUrl {
    $state = Read-SdServerState
    if ($state -and $state.host -and $state.port -and (Test-SdServerAlive $state)) {
        $h = if ($state.host -eq '0.0.0.0') { '127.0.0.1' } else { [string]$state.host }
        return "http://${h}:$($state.port)"
    }
    return $script:baseUrlFallback
}

# ── HTTP helper ──────────────────────────────────────────────────────
function Invoke-SdJson {
    param([string]$Method, [string]$Path, $Body, [int]$TimeoutSec = -1)
    $url     = (Get-SdServerBaseUrl) + $Path
    $timeout = if ($TimeoutSec -gt 0) { $TimeoutSec } else { $RequestTimeoutSec }
    $params  = @{
        Uri         = $url
        Method      = $Method
        TimeoutSec  = $timeout
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body        = ($Body | ConvertTo-Json -Depth 100 -Compress)
    }
    try {
        return Invoke-RestMethod @params
    } catch [Microsoft.PowerShell.Commands.HttpResponseException] {
        # Surface sd-server's JSON error payload (e.g. "invalid ref_images")
        # instead of the bare "Response status code does not indicate
        # success" — the body is the only diagnostic sd-server gives.
        $detail = $_.ErrorDetails.Message
        if ($detail) {
            # Throw a real [Exception] (not a string) and stash the HTTP status
            # in .Data — a string throw erases both the exception type and the
            # status code, and check_image_job needs to key 404 off it.
            $ex = [System.Exception]::new("sd-server returned an error for $Method $Path — $($_.Exception.Message) Body: $detail")
            $ex.Data['StatusCode'] = [int]$_.Exception.Response.StatusCode
            throw $ex
        }
        throw
    }
}

# ── Progress notifications ───────────────────────────────────────────
# Writes a JSON-RPC notification to stdout. Used to stream progress
# during long-running tool calls when the client passed a progressToken
# in tools/call params._meta. Notifications carry no id and expect no
# reply. MCP spec requires `progress` to increase monotonically; we use
# elapsed seconds, which satisfies that.
function Send-RpcNotification {
    param([string]$Method, [hashtable]$Params)
    $msg = @{ jsonrpc = '2.0'; method = $Method; params = $Params }
    try {
        [Console]::Out.WriteLine(($msg | ConvertTo-Json -Compress -Depth 100))
        [Console]::Out.Flush()
    } catch {
        Write-Log WARN "failed to send notification: $($_.Exception.Message)"
    }
}

# ── Tool: generate_image ─────────────────────────────────────────────
# Accepts a file path OR an already-encoded image string (raw base64 or
# a data:image/...;base64,... URL). sd-server strips the data: prefix
# itself, so we pass data URLs through unmodified.
function Resolve-ImageArgument {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value.StartsWith('data:')) { return $Value }
    if (Test-Path -LiteralPath $Value -PathType Leaf) {
        $full  = (Resolve-Path -LiteralPath $Value).Path
        $bytes = [System.IO.File]::ReadAllBytes($full)
        Write-Log INFO ("loaded reference image from disk: {0} ({1} bytes)" -f $full, $bytes.Length)
        return [Convert]::ToBase64String($bytes)
    }
    return $Value
}

# Some models are trained exclusively on structured JSON captions —
# currently Ideogram4 (Qwen3-VL text encoder): high_level_description /
# style_description / compositional_deconstruction. Fed plain text their
# conditioning goes degenerate and EVERY render comes out as a flat grey
# "blocked" card, so generate_image fails fast and steers the caller to
# `prompt_json` instead. Detection is name-based: /capabilities only
# exposes the diffusion-model filename (and the state file the preset
# id) — neither names the text encoder.
function Test-WantsStructuredJsonPrompt {
    $name = $null
    try {
        $caps = Invoke-SdJson -Method GET -Path '/sdcpp/v1/capabilities' -TimeoutSec 5
        $name = [string]$caps.model.name
    } catch {
        $state = Read-SdServerState
        if ($state) { $name = [string]$state.preset }
    }
    return [bool]($name -and $name -match 'ideogram')
}

# sd-server's APIs intentionally refuse <lora:...> prompt tags; LoRAs must
# arrive as the structured `lora` array on each img_gen request, and there is
# no server-side per-model default. Per-preset LoRAs are therefore an INI
# contract owned by this bridge: the active preset's `lora` key holds FULL
# file paths with optional :<multiplier> (see ConvertTo-LoraEntries in
# common-functions.ps1). run-server.ps1 derives --lora-model-dir from the
# first entry's parent directory, so what sd-server's resolver wants here is
# the path RELATIVE to that dir — i.e. the bare filename (which is also why
# all of a preset's LoRAs must share one directory). The built-in web UI has
# its own LoRA selector and ignores this key.
function Get-ActivePresetLoraList {
    # -State lets a caller pass an already-read sd-server.state so we don't
    # re-read it (Invoke-GenerateImage reads it once for both this and the
    # sidecar). Omitted → read it ourselves, so list_presets etc. stay
    # self-sufficient.
    param($State)
    if ($PSBoundParameters.ContainsKey('State')) { $state = $State } else { $state = Read-SdServerState }
    $presetId = if ($state) { [string]$state.preset } else { $null }
    if (-not $presetId) { return @() }

    $presetsPath = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config\presets.ini"
    $preset = @(Get-Presets -Path $presetsPath) | Where-Object { $_.Id -eq $presetId } | Select-Object -First 1
    if (-not $preset -or -not $preset.Keys['lora']) { return @() }

    # sd-server resolves every injected LoRA against ONE --lora-model-dir (the
    # first entry's parent, picked by run-server.ps1), so a second LoRA from a
    # different folder fails cryptically at render. Warn once if the dirs differ.
    $parsed   = @(ConvertTo-LoraEntries -Value ([string]$preset.Keys['lora']))
    $firstDir = if ($parsed.Count -gt 0) { Split-Path -Parent $parsed[0].Path } else { '' }
    $multiDir = $false
    $entries = @()
    foreach ($e in $parsed) {
        $dir = Split-Path -Parent $e.Path
        if ($dir -and $firstDir -and ($dir -ine $firstDir)) { $multiDir = $true }
        $entries += @{ path = [System.IO.Path]::GetFileName($e.Path); multiplier = $e.Multiplier }
    }
    if ($multiDir) {
        Write-Log WARN ("preset '{0}' has LoRA entries in more than one directory; sd-server resolves all of them against '{1}' (the first entry's parent), so LoRAs from other folders will not load." -f $presetId, $firstDir)
    }
    # No `,$entries`: the caller collects with @(...), and a comma-wrapper
    # would nest ([[{...}]] in the JSON body — sd-server 400s on it).
    return $entries
}

function Invoke-GenerateImage {
    param([hashtable]$Arguments, $ProgressToken = $null)

    # Read sd-server.state ONCE: both the LoRA injection (Get-ActivePresetLoraList)
    # and the params sidecar's `preset` field need it, and re-reading risks them
    # disagreeing if a switch_preset lands mid-call.
    $serverState = Read-SdServerState

    # Prompt comes in one of two shapes: plain `prompt` (string) or
    # `prompt_json` (object) for JSON-caption-native models. The object
    # form is serialized compactly HERE so the client model never has to
    # hand-escape a multi-KB JSON caption into a quoted string (same
    # truncation risk as inline base64). prompt_json wins when both are set.
    $promptText = $null
    if ($Arguments -and $Arguments.ContainsKey('prompt_json') -and $null -ne $Arguments['prompt_json']) {
        $pj = $Arguments['prompt_json']
        if ($pj -is [string]) {
            # Tolerate clients that pre-serialize the object themselves,
            # but reject strings that aren't actually a JSON object —
            # scalars like "5" or "true" parse fine yet make no caption.
            if (-not $pj.TrimStart().StartsWith('{')) {
                throw "prompt_json was passed as a string but it is not a JSON object (must start with '{')"
            }
            try { $null = $pj | ConvertFrom-Json -Depth 100 } catch {
                throw "prompt_json was passed as a string but it is not valid JSON: $($_.Exception.Message)"
            }
            $promptText = $pj
        } else {
            $promptText = ConvertTo-Json -InputObject $pj -Depth 100 -Compress
        }
        Write-Log INFO ("prompt_json supplied; serialized to {0} chars" -f $promptText.Length)
    } elseif ($Arguments -and $Arguments.ContainsKey('prompt') -and
              -not [string]::IsNullOrWhiteSpace([string]$Arguments['prompt'])) {
        $promptText = [string]$Arguments['prompt']
        if (-not $promptText.TrimStart().StartsWith('{') -and (Test-WantsStructuredJsonPrompt)) {
            throw ('the active model is trained exclusively on structured JSON captions; a plain-text prompt degenerates into a grey "blocked" card on every render. Re-call generate_image with prompt_json: an object shaped {high_level_description: string, style_description: {aesthetics, lighting, photo, medium, color_palette: ["#hex",...]}, compositional_deconstruction: {canvas, background, layout, elements: [{type: "text"|"obj", desc: string},...]}}. Write the full caption yourself: exhaustively descriptive, every object named explicitly; spell any in-image text verbatim in a "text" element.')
        }
    } else {
        throw 'missing required argument: provide prompt (plain text) or prompt_json (structured caption object)'
    }

    # Translate flat MCP args → sd-server's nested gen_params schema.
    # Top-level: prompt, negative_prompt, width, height, batch_count, seed,
    #   init_image, ref_images, strength, auto_resize_ref_image.
    # Nested under sample_params: sample_steps, sample_method, scheduler,
    #   plus guidance.txt_cfg / guidance.distilled_guidance.
    $sampleParams = @{}
    $guidance     = @{}

    if ($Arguments.ContainsKey('steps'))       { $sampleParams.sample_steps  = [int]$Arguments['steps'] }
    if ($Arguments.ContainsKey('sampler'))     { $sampleParams.sample_method = [string]$Arguments['sampler'] }
    if ($Arguments.ContainsKey('scheduler'))   { $sampleParams.scheduler     = [string]$Arguments['scheduler'] }
    if ($Arguments.ContainsKey('flow_shift'))  { $sampleParams.flow_shift    = [double]$Arguments['flow_shift'] }
    if ($Arguments.ContainsKey('cfg_scale'))   { $guidance.txt_cfg            = [double]$Arguments['cfg_scale'] }
    if ($Arguments.ContainsKey('guidance'))    { $guidance.distilled_guidance = [double]$Arguments['guidance'] }
    if ($guidance.Count -gt 0)                 { $sampleParams.guidance      = $guidance }

    $body = @{
        prompt             = $promptText
        width              = if ($Arguments.ContainsKey('width'))       { [int]$Arguments['width'] }       else { 1024 }
        height             = if ($Arguments.ContainsKey('height'))      { [int]$Arguments['height'] }      else { 1024 }
        batch_count        = if ($Arguments.ContainsKey('batch_count')) { [int]$Arguments['batch_count'] } else { 1 }
        output_format      = if ($Arguments.ContainsKey('output_format')) { [string]$Arguments['output_format'] } else { 'jpeg' }
        output_compression = if ($Arguments.ContainsKey('output_compression')) { [int]$Arguments['output_compression'] } else { 90 }
    }
    if ($Arguments.ContainsKey('negative_prompt')) { $body.negative_prompt = [string]$Arguments['negative_prompt'] }
    if ($Arguments.ContainsKey('seed'))            { $body.seed            = [int64]$Arguments['seed'] }
    if ($sampleParams.Count -gt 0)                 { $body.sample_params   = $sampleParams }

    # Reference / init image inputs. init_image triggers img2img; ref_images
    # feeds reference-aware models (Flux Kontext, etc.). Both accept file
    # paths or base64 strings; strength only matters with init_image.
    $refCount = 0
    if ($Arguments.ContainsKey('init_image')) {
        $enc = Resolve-ImageArgument -Value ([string]$Arguments['init_image'])
        if ($enc) { $body.init_image = $enc }
    }
    if ($Arguments.ContainsKey('ref_images') -and $Arguments['ref_images']) {
        $refs = @()
        foreach ($r in @($Arguments['ref_images'])) {
            $enc = Resolve-ImageArgument -Value ([string]$r)
            if ($enc) { $refs += $enc }
        }
        if ($refs.Count -gt 0) {
            $body.ref_images = $refs
            $refCount        = $refs.Count
        }
    }
    if ($Arguments.ContainsKey('strength'))              { $body.strength              = [double]$Arguments['strength'] }
    if ($Arguments.ContainsKey('auto_resize_ref_image')) { $body.auto_resize_ref_image = [bool]$Arguments['auto_resize_ref_image'] }

    # Per-preset LoRAs from the INI `lora` key (see Get-ActivePresetLoraList).
    # `lora_multiplier` overrides the INI multiplier for this request only
    # (applies to every entry; 0 disables the preset LoRAs entirely). The
    # INI value (e.g. :0.6) stays the default when the arg is omitted.
    $loraList = @(Get-ActivePresetLoraList -State $serverState)
    if ($Arguments.ContainsKey('lora_multiplier')) {
        $loraMult = [double]$Arguments['lora_multiplier']
        if ($loraList.Count -eq 0) {
            Write-Log WARN 'lora_multiplier supplied but the active preset has no lora key - ignored'
        } elseif ($loraMult -eq 0) {
            Write-Log INFO 'lora_multiplier=0: preset LoRAs disabled for this request'
            $loraList = @()
        } else {
            # Rebuild fresh hashtables rather than mutating the ones returned by
            # Get-ActivePresetLoraList in place — if that ever gets memoised, an
            # in-place edit here would poison the cached list for later requests.
            $loraList = @(foreach ($l in $loraList) { @{ path = $l.path; multiplier = $loraMult } })
        }
    }
    if ($loraList.Count -gt 0) {
        $body.lora = $loraList
        # Invariant culture: -f would render 0.6 as "0,6" under it-IT.
        Write-Log INFO ("preset LoRAs injected: {0}" -f (@(
            foreach ($l in $loraList) {
                '{0}:{1}' -f $l.path, $l.multiplier.ToString([Globalization.CultureInfo]::InvariantCulture)
            }) -join ', '))
    }

    $promptPreview = $body.prompt.Substring(0, [Math]::Min(60, $body.prompt.Length))
    $hasInit       = if ($body.ContainsKey('init_image')) { 'yes' } else { 'no' }
    Write-Log INFO ("submit img_gen: '{0}...' {1}x{2} batch={3} fmt={4} init_image={5} ref_images={6}" -f
        $promptPreview, $body.width, $body.height, $body.batch_count, $body.output_format, $hasInit, $refCount)

    $submit = Invoke-SdJson -Method POST -Path '/sdcpp/v1/img_gen' -Body $body
    $jobId  = $submit.id
    if (-not $jobId) {
        throw "sd-server did not return a job id (response: $($submit | ConvertTo-Json -Compress -Depth 5))"
    }
    Write-Log INFO "job submitted: $jobId"

    # Build the job metadata once, up front, so it survives the async gap:
    # check_image_job (which only ever receives a job_id) reads it back to
    # honour save_path / return_inline and to write the params sidecar.
    # `snapshot` is the replayable request record — everything but the
    # per-image seeds and saved file paths, which only exist once the render
    # finishes (Complete-ImageJob appends those).
    $wait = $false
    if ($Arguments.ContainsKey('wait')) { $wait = [bool]$Arguments['wait'] }

    $savePath = if ($Arguments.ContainsKey('save_path')) { [string]$Arguments['save_path'] } else { '' }
    $returnInline = if ($Arguments.ContainsKey('return_inline')) {
        [bool]$Arguments['return_inline']
    } else {
        [string]::IsNullOrWhiteSpace($savePath)
    }

    $snapshot = [ordered]@{ timestamp = (Get-Date).ToString('o') }
    # Reuse the state read once at the top of this function (see $serverState).
    if ($serverState -and $serverState.preset) { $snapshot.preset = [string]$serverState.preset }
    $snapshot.prompt = $body.prompt
    if ($body.ContainsKey('negative_prompt')) { $snapshot.negative_prompt = $body.negative_prompt }
    $snapshot.width       = $body.width
    $snapshot.height      = $body.height
    $snapshot.batch_count = $body.batch_count
    if ($body.ContainsKey('seed')) { $snapshot.seed = $body.seed }
    if ($body.sample_params) {
        $sp = $body.sample_params
        if ($sp.sample_method) { $snapshot.sampler   = $sp.sample_method }
        if ($sp.sample_steps)  { $snapshot.steps     = $sp.sample_steps }
        if ($sp.scheduler)     { $snapshot.scheduler = $sp.scheduler }
        if ($sp.flow_shift)    { $snapshot.flow_shift = $sp.flow_shift }
        if ($sp.guidance) {
            if ($null -ne $sp.guidance.txt_cfg)            { $snapshot.cfg_scale = $sp.guidance.txt_cfg }
            if ($null -ne $sp.guidance.distilled_guidance) { $snapshot.guidance  = $sp.guidance.distilled_guidance }
        }
    }
    $snapshot.output_format = $body.output_format
    if ($body.ContainsKey('output_compression')) { $snapshot.output_compression = $body.output_compression }
    if ($Arguments.ContainsKey('init_image')) {
        $orig = [string]$Arguments['init_image']
        $snapshot.init_image = if (Test-Path -LiteralPath $orig -PathType Leaf) {
            (Resolve-Path -LiteralPath $orig).Path
        } else { '<inline base64 / data URL>' }
    }
    if ($Arguments.ContainsKey('ref_images') -and $Arguments['ref_images']) {
        $snapshot.ref_images = @(
            foreach ($r in @($Arguments['ref_images'])) {
                $rs = [string]$r
                if (Test-Path -LiteralPath $rs -PathType Leaf) {
                    (Resolve-Path -LiteralPath $rs).Path
                } else { '<inline base64 / data URL>' }
            }
        )
    }
    if ($body.ContainsKey('strength'))              { $snapshot.strength              = $body.strength }
    if ($body.ContainsKey('auto_resize_ref_image')) { $snapshot.auto_resize_ref_image = $body.auto_resize_ref_image }
    if ($body.ContainsKey('lora')) {
        # Invariant culture so the sidecar stays replayable ("0.6", not the
        # it-IT "0,6" that -f would produce).
        $snapshot.lora = @(foreach ($l in $body.lora) {
            '{0}:{1}' -f $l.path, $l.multiplier.ToString([Globalization.CultureInfo]::InvariantCulture)
        })
    }
    $meta = [ordered]@{
        started_at    = (Get-Date).ToString('o')
        save_path     = $savePath
        return_inline = $returnInline
        snapshot      = $snapshot
    }

    # Fire-and-forget (the default): stash the meta and hand back the job id
    # immediately. The caller polls check_image_job for progress + the image.
    if (-not $wait) {
        Save-JobMeta -JobId $jobId -Meta $meta
        # For save_path jobs, spawn a detached collector so the image lands on
        # disk even if the client never polls in time: sd-server discards a
        # completed result after 600s (completed_ttl_seconds) and the bridge
        # only writes to disk when it collects. Inline-only jobs (no save_path)
        # have no disk target, so they still rely on the client polling.
        $autoSave = -not [string]::IsNullOrWhiteSpace($savePath)
        if ($autoSave) { Start-CollectorProcess -JobId $jobId }
        $msg = 'Image generation started (fire-and-forget). Poll check_image_job with this job_id for progress and the finished image; cancel with cancel_image_job.'
        if ($autoSave) {
            $msg += ' A background collector will save the finished image to the requested save_path automatically, so it is not lost even if you do not poll in time.'
        }
        $payload = [ordered]@{
            job_id  = $jobId
            status  = 'submitted'
            message = $msg
        }
        Write-Log INFO ("generate_image async: returned job_id {0} (collector={1})" -f $jobId, $autoSave)
        return @{ content = @(@{ type = 'text'; text = ($payload | ConvertTo-Json -Depth 5) }) }
    }

    # wait=true: block until the render is done, streaming progress. Emit an
    # initial progress event so the client gets immediate feedback even
    # before sd-server transitions out of "queued".
    if ($null -ne $ProgressToken) {
        Send-RpcNotification 'notifications/progress' @{
            progressToken = $ProgressToken
            progress      = 0
            message       = "submitted job $jobId"
        }
    }

    # Poll until completion / failure / timeout. sd-server has no
    # step-level progress endpoint, so we stream:
    #   - status transitions (queued → generating)
    #   - a once-per-second heartbeat with elapsed seconds
    # That's the finest granularity sd-server's job API gives us.
    $pollUrl     = "/sdcpp/v1/jobs/$jobId"
    $started     = Get-Date
    $deadline    = $started.AddSeconds($RequestTimeoutSec)
    $job         = $null
    $lastStatus  = ''
    $lastTick    = -1
    $pollFails   = 0
    while ($true) {
        Start-Sleep -Milliseconds $PollIntervalMs
        # Short per-poll timeout (the default would be the full request
        # timeout, letting one hung poll outlive the job deadline) and
        # tolerance for transient hiccups — the job keeps rendering server-
        # side, so aborting on a single connection reset wastes the render.
        try {
            $job = Invoke-SdJson -Method GET -Path $pollUrl -TimeoutSec 10
            $pollFails = 0
        } catch {
            $pollFails++
            Write-Log WARN "poll $pollFails/3 failed for job ${jobId}: $($_.Exception.Message)"
            if ($pollFails -ge 3) {
                try { Invoke-SdJson -Method POST -Path "$pollUrl/cancel" -TimeoutSec 10 | Out-Null } catch {}
                throw "lost contact with sd-server while polling job $jobId (3 consecutive failures): $($_.Exception.Message)"
            }
            continue
        }

        if ($null -ne $ProgressToken) {
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            $emit    = $false
            $msg     = $null
            if ($job.status -ne $lastStatus) {
                $emit = $true
                $msg  = switch ($job.status) {
                    'queued'     { "queued (position $($job.queue_position))" }
                    'generating' { "generating..." }
                    default      { "status: $($job.status)" }
                }
                $lastStatus = $job.status
            } elseif ($elapsed -ne $lastTick -and $job.status -eq 'generating') {
                $emit = $true
                $msg  = "generating... ${elapsed}s elapsed"
            }
            if ($emit) {
                Send-RpcNotification 'notifications/progress' @{
                    progressToken = $ProgressToken
                    progress      = $elapsed
                    message       = $msg
                }
                $lastTick = $elapsed
            }
        }

        if ($job.status -in @('completed', 'failed', 'cancelled')) { break }
        if ((Get-Date) -gt $deadline) {
            try { Invoke-SdJson -Method POST -Path "$pollUrl/cancel" | Out-Null } catch {}
            throw "job $jobId timed out after ${RequestTimeoutSec}s (last status: $($job.status))"
        }
    }

    if ($job.status -ne 'completed') {
        $errMsg = if ($job.error) { "$($job.error.code): $($job.error.message)" } else { 'unknown error' }
        throw "job $jobId $($job.status) — $errMsg"
    }

    # Round-trip meta through JSON so Complete-ImageJob always sees the same
    # PSCustomObject shape it gets from check_image_job's on-disk meta file.
    return Complete-ImageJob -Job $job -Meta ($meta | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
}

# ── Result delivery (shared) ─────────────────────────────────────────
# Turns a COMPLETED sd-server job into the MCP tool result: optional disk
# save (+ params sidecar), optional inline base64, summary text. Used by
# generate_image's wait-mode and by check_image_job. $Meta is the record
# stashed at submit time (started_at / save_path / return_inline / snapshot);
# $null is tolerated (job submitted outside this server, no meta on disk) and
# degrades to "inline only".
function Complete-ImageJob {
    param($Job, $Meta)

    $images = @($Job.result.images)
    if ($images.Count -eq 0) { throw "job completed but returned no images" }

    $mime = switch ([string]$Job.result.output_format) {
        'png'  { 'image/png' }
        'jpeg' { 'image/jpeg' }
        'webp' { 'image/webp' }
        default { 'application/octet-stream' }
    }

    $savePath = if ($Meta -and $Meta.save_path) { [string]$Meta.save_path } else { '' }
    $returnInline = if ($Meta -and ($null -ne $Meta.return_inline)) {
        [bool]$Meta.return_inline
    } else {
        [string]::IsNullOrWhiteSpace($savePath)
    }
    $started = if ($Meta -and $Meta.started_at) {
        try { (ConvertTo-StartedDto $Meta.started_at).LocalDateTime } catch { Get-Date }
    } else { Get-Date }

    $savedPaths   = @()
    $savedSidecar = $null
    if (-not [string]::IsNullOrWhiteSpace($savePath)) {
        # Resolve relative paths against the MCP server's CWD (set by
        # run-server.ps1 to %LOCALAPPDATA%\stable-diffusion.cpp when launched
        # via the installer; arbitrary otherwise). Caller should pass absolute
        # to avoid surprises.
        $resolved = [System.IO.Path]::GetFullPath($savePath)
        $parent   = [System.IO.Path]::GetDirectoryName($resolved)
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if ($images.Count -eq 1) {
            $bytes = [Convert]::FromBase64String([string]$images[0].b64_json)
            [System.IO.File]::WriteAllBytes($resolved, $bytes)
            $savedPaths += $resolved
            Write-Log INFO ("saved image to {0} ({1} bytes)" -f $resolved, $bytes.Length)
        } else {
            $dir  = [System.IO.Path]::GetDirectoryName($resolved)
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($resolved)
            $ext  = [System.IO.Path]::GetExtension($resolved)
            for ($i = 0; $i -lt $images.Count; $i++) {
                $suffix = '{0:D3}' -f ($i + 1)
                $name   = "{0}_{1}{2}" -f $stem, $suffix, $ext
                $p      = if ($dir) { Join-Path $dir $name } else { $name }
                $bytes  = [Convert]::FromBase64String([string]$images[$i].b64_json)
                [System.IO.File]::WriteAllBytes($p, $bytes)
                $savedPaths += $p
                Write-Log INFO ("saved image {0}/{1} to {2} ({3} bytes)" -f ($i+1), $images.Count, $p, $bytes.Length)
            }
        }

        # ── Params sidecar ───────────────────────────────────────────
        # The replayable request record stashed at submit time, now finished
        # with the per-image seeds sd-server reported and the saved file
        # paths. One JSON per request, named after $save_path's stem (no _NNN
        # suffix even for a batch — it describes the request, not a frame).
        $resolvedSidecar = [System.IO.Path]::ChangeExtension($resolved, '.json')
        $snapshot = [ordered]@{}
        if ($Meta -and $Meta.snapshot) {
            foreach ($prop in $Meta.snapshot.PSObject.Properties) { $snapshot[$prop.Name] = $prop.Value }
        }
        $seedsUsed = @(foreach ($img in $images) { if ($null -ne $img.seed) { $img.seed } })
        if ($seedsUsed.Count -gt 0) { $snapshot.seeds_used = $seedsUsed }
        $snapshot.saved_images = $savedPaths

        try {
            $sidecarJson = $snapshot | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($resolvedSidecar, $sidecarJson, [System.Text.UTF8Encoding]::new($false))
            $savedSidecar = $resolvedSidecar
            Write-Log INFO ("saved params sidecar: {0}" -f $resolvedSidecar)
        } catch {
            Write-Log WARN ("failed to write params sidecar {0}: {1}" -f $resolvedSidecar, $_.Exception.Message)
        }
    }

    # annotations hint to MCP clients that the image is meant for the user
    # to see (audience=user, high priority) — by-the-book per MCP spec. Note:
    # claude.ai web is reported to ignore the hint and not render inline
    # regardless (modelcontextprotocol/specification issue #238); Claude Code
    # honours it. Doesn't hurt to send it.
    $imageContents = @()
    if ($returnInline) {
        foreach ($img in $images) {
            $imageContents += @{
                type        = 'image'
                data        = [string]$img.b64_json
                mimeType    = $mime
                annotations = @{ audience = @('user'); priority = 0.9 }
            }
        }
    }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    $summary = "Generated $($images.Count) image(s) in ${elapsed}s."
    if ($savedPaths.Count -gt 0) {
        $summary += " Saved to: " + ($savedPaths -join '; ') + "."
    }
    if ($savedSidecar) {
        $summary += " Params sidecar: $savedSidecar."
    }
    if (-not $returnInline) {
        $summary += " (Inline image omitted; pass return_inline=true to also embed.)"
    }
    Write-Log INFO ("job completed in {0}s — {1} image(s), inline={2}, saved={3}, sidecar={4}" -f
        $elapsed, $images.Count, $returnInline, $savedPaths.Count, [bool]$savedSidecar)

    return @{ content = @(@{ type = 'text'; text = $summary }) + $imageContents }
}

# ── Async job metadata persistence ───────────────────────────────────
# generate_image is fire-and-forget by default: it submits to sd-server's
# async /sdcpp/v1/img_gen and returns the job id immediately; check_image_job
# fetches the result later. To carry save_path / sidecar params /
# return_inline / start time across that gap (the status call only receives a
# job id) we stash a small JSON per job under run\jobs\. check_image_job /
# cancel_image_job read + delete it on terminal status; a missing file just
# means "deliver inline only" (e.g. a job started by the web UI).
$script:JobsDir = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\run\jobs"

# Startup GC: jobs that were never polled (the client crashed or wandered off)
# would otherwise pile up forever and clutter the no-arg check_image_job list.
# Drop meta files older than 7 days — well past any realistic render time.
try {
    if (Test-Path -LiteralPath $script:JobsDir) {
        $cutoff = (Get-Date).AddDays(-7)
        Get-ChildItem -LiteralPath $script:JobsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
} catch {}

# started_at is written as an ISO-8601 'o' string, but ConvertFrom-Json
# auto-parses date-like strings into [datetime] when reading the meta back.
# Re-parsing a [datetime] through [datetimeoffset]::Parse (a string API) would
# round-trip it through the it-IT culture and mangle the value, so normalise
# both shapes here.
function ConvertTo-StartedDto {
    param($Value)
    if ($Value -is [datetimeoffset]) { return $Value }
    if ($Value -is [datetime])       { return [datetimeoffset]$Value }
    return [datetimeoffset]::Parse([string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
}

function Get-JobMetaPath {
    param([string]$JobId)
    # Server ids are uuid/hex; refuse anything that could escape the jobs dir
    # before using it as a filename.
    if ([string]::IsNullOrWhiteSpace($JobId) -or $JobId -notmatch '^[A-Za-z0-9_.-]+$') { return $null }
    return (Join-Path $script:JobsDir ("{0}.json" -f $JobId))
}

function Save-JobMeta {
    param([string]$JobId, $Meta)
    $path = Get-JobMetaPath $JobId
    if (-not $path) { return }
    try {
        New-Item -ItemType Directory -Path $script:JobsDir -Force | Out-Null
        $json = $Meta | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Log WARN ("failed to persist job meta for {0}: {1}" -f $JobId, $_.Exception.Message)
    }
}

function Read-JobMeta {
    param([string]$JobId)
    $path = Get-JobMetaPath $JobId
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch {
        Write-Log WARN ("failed to read job meta for {0}: {1}" -f $JobId, $_.Exception.Message)
        return $null
    }
}

function Remove-JobMeta {
    param([string]$JobId)
    $path = Get-JobMetaPath $JobId
    if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

# Spawn a detached background collector for a fire-and-forget job. The child
# re-enters THIS script with -CollectJob <id>, reusing every helper defined
# here, and polls the job to completion then saves it to disk through
# Complete-ImageJob — so delivery no longer depends on the client polling
# check_image_job within sd-server's 600s completed-result TTL. Only meaningful
# when the job has a save_path: the collector's only delivery channel is disk
# (it has no MCP client to return inline to). Best-effort — a spawn failure
# just degrades to the old poll-it-yourself behaviour.
function Start-CollectorProcess {
    param([string]$JobId)
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) {
        Write-Log WARN "pwsh.exe not on PATH; cannot spawn collector for $JobId"
        return
    }
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Log WARN "cannot resolve own script path; no collector for $JobId"
        return
    }
    # Single-string -ArgumentList with every path quoted: Start-Process does not
    # quote array elements, so a "Program Files" path would split (mirrors
    # Start-SdServer). JobId matches ^[A-Za-z0-9_.-]+$ so it needs no escaping,
    # but quote it for symmetry. Pass -ServerIni / -LogPath through so the
    # collector resolves the same endpoint and logs to the same file.
    $argString = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -CollectJob "{1}" -ServerIni "{2}" -LogPath "{3}"' -f `
        $PSCommandPath, $JobId, $ServerIni, $LogPath
    try {
        Start-Process -FilePath $pwshCmd.Source -ArgumentList $argString -WindowStyle Hidden | Out-Null
        Write-Log INFO "spawned background collector for job $JobId"
    } catch {
        Write-Log WARN ("failed to spawn collector for {0}: {1}" -f $JobId, $_.Exception.Message)
    }
}

# ── Tool: check_image_job ────────────────────────────────────────────
# Poll one async generate_image job by id (single GET, no blocking). While
# pending → status + queue_position + elapsed. On completion → delivers the
# image (inline / save_path) via Complete-ImageJob, honouring the save_path /
# return_inline stashed at submit, then forgets the job. On failure/cancel →
# isError with the server's reason. Called with no job_id → lists the jobs
# this server is locally tracking.
function Invoke-CheckImageJob {
    param([hashtable]$Arguments)

    $jobId = if ($Arguments -and $Arguments.ContainsKey('job_id')) { [string]$Arguments['job_id'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($jobId)) { return (Get-PendingJobList) }

    # A 404 means sd-server RESPONDED but has forgotten this job (it was
    # restarted, or the id is bogus). Without this the bare throw would skip
    # Remove-JobMeta and leave a zombie meta file polluting the pending list
    # forever, with no escape hatch — so on 404 only, drop the meta and report
    # cleanly. Any OTHER failure (connection refused, timeout) is NOT proof the
    # job is gone, so we rethrow and keep the meta for a later retry.
    try {
        $job = Invoke-SdJson -Method GET -Path "/sdcpp/v1/jobs/$jobId" -TimeoutSec 10
    } catch {
        # Invoke-SdJson re-throws HTTP errors that carry a body as a plain
        # [Exception] with the status in .Data (the usual case — sd-server's
        # 404 has a JSON body); only a body-less error surfaces as the original
        # HttpResponseException. Handle both shapes.
        $httpStatus = $null
        if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
            $httpStatus = [int]$_.Exception.Response.StatusCode
        } elseif ($_.Exception.Data -and $_.Exception.Data.Contains('StatusCode')) {
            $httpStatus = [int]$_.Exception.Data['StatusCode']
        }
        if ($httpStatus -eq 404) {
            Remove-JobMeta $jobId
            Write-Log WARN ("check_image_job: {0} unknown to sd-server (404) — dropping local tracking" -f $jobId)
            return @{ content = @(@{ type = 'text'; text = (([ordered]@{
                job_id = $jobId; status = 'unknown'; done = $true
                message = 'sd-server does not know this job (it was likely restarted). Local tracking for it has been dropped.'
            }) | ConvertTo-Json -Depth 5) }) }
        }
        throw
    }
    $status = [string]$job.status

    if ($status -in @('queued', 'generating')) {
        $meta    = Read-JobMeta $jobId
        $payload = [ordered]@{ job_id = $jobId; status = $status; done = $false }
        if ($null -ne $job.queue_position) { $payload.queue_position = $job.queue_position }
        if ($meta -and $meta.started_at) {
            try { $payload.elapsed_sec = [int]([datetimeoffset]::Now - (ConvertTo-StartedDto $meta.started_at)).TotalSeconds } catch {}
        }
        $payload.message = 'Not finished yet — call check_image_job again with this job_id.'
        Write-Log INFO ("check_image_job: {0} status={1}" -f $jobId, $status)
        return @{ content = @(@{ type = 'text'; text = ($payload | ConvertTo-Json -Depth 5) }) }
    }

    if ($status -eq 'completed') {
        $meta   = Read-JobMeta $jobId
        $result = Complete-ImageJob -Job $job -Meta $meta
        Remove-JobMeta $jobId
        Write-Log INFO ("check_image_job: {0} completed, delivered" -f $jobId)
        return $result
    }

    # failed / cancelled / anything else terminal
    Remove-JobMeta $jobId
    $errMsg = if ($job.error) { "$($job.error.code): $($job.error.message)" } else { 'unknown error' }
    Write-Log WARN ("check_image_job: {0} {1} — {2}" -f $jobId, $status, $errMsg)
    return @{
        content = @(@{ type = 'text'; text = (([ordered]@{ job_id = $jobId; status = $status; done = $true; error = $errMsg }) | ConvertTo-Json -Depth 5) })
        isError = $true
    }
}

# List the jobs this server stashed locally (one meta file each). These are
# the in-flight fire-and-forget jobs; completed/failed ones are removed once
# check_image_job fetches them.
function Get-PendingJobList {
    $jobs = @()
    if (Test-Path -LiteralPath $script:JobsDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $script:JobsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            $jobId = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            # Reuse Read-JobMeta so the meta-read (and its id validation) lives
            # in one place rather than a duplicated inline ConvertFrom-Json.
            $m     = Read-JobMeta $jobId
            $entry = [ordered]@{ job_id = $jobId }
            if ($m) {
                if ($m.started_at) { $entry.started_at = $m.started_at }
                if ($m.save_path)  { $entry.save_path  = $m.save_path }
                if ($m.snapshot -and $m.snapshot.prompt) {
                    $p = [string]$m.snapshot.prompt
                    $entry.prompt = $p.Substring(0, [Math]::Min(80, $p.Length))
                }
            }
            $jobs += $entry
        }
    }
    $payload = [ordered]@{
        pending_jobs = $jobs
        count        = $jobs.Count
        note         = 'Jobs this MCP server is tracking locally. Pass a job_id to check_image_job for its status/result; completed or failed jobs are dropped once fetched.'
    }
    return @{ content = @(@{ type = 'text'; text = ($payload | ConvertTo-Json -Depth 6) }) }
}

# ── Tool: cancel_image_job ───────────────────────────────────────────
# Ask sd-server to cancel a queued/running job and drop our local meta. A
# job that already finished (or never existed) is reported, not an error.
function Invoke-CancelImageJob {
    param([hashtable]$Arguments)
    if (-not $Arguments -or
        -not $Arguments.ContainsKey('job_id') -or
        [string]::IsNullOrWhiteSpace([string]$Arguments['job_id'])) {
        throw "missing required argument: job_id"
    }
    $jobId = [string]$Arguments['job_id']
    $msg = ''
    try {
        Invoke-SdJson -Method POST -Path "/sdcpp/v1/jobs/$jobId/cancel" -TimeoutSec 10 | Out-Null
        $msg = "Requested cancellation of job '$jobId'."
    } catch {
        $msg = "Could not cancel job '$jobId' (it may already be finished or unknown): $($_.Exception.Message)"
    }
    Remove-JobMeta $jobId
    Write-Log INFO "cancel_image_job: $msg"
    return @{ content = @(@{ type = 'text'; text = $msg }) }
}

# ── Tool: encode_file_base64 ─────────────────────────────────────────
# Reads a local file and returns its base64 representation as a text
# block. Intended for staging reference / init images that will be passed
# into generate_image, but works for any binary file. Capped at 25 MB raw
# (≈ 34 MB base64) by default to keep model context costs sane; override
# with max_bytes.
function Invoke-EncodeFileBase64 {
    param([hashtable]$Arguments)

    if (-not $Arguments -or
        -not $Arguments.ContainsKey('path') -or
        [string]::IsNullOrWhiteSpace([string]$Arguments['path'])) {
        throw "missing required argument: path"
    }

    $path = [string]$Arguments['path']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "file not found: $path"
    }
    $full = (Resolve-Path -LiteralPath $path).Path
    $info = Get-Item -LiteralPath $full

    $maxBytes = if ($Arguments.ContainsKey('max_bytes')) { [int64]$Arguments['max_bytes'] } else { 26214400 }
    if ($info.Length -gt $maxBytes) {
        throw ("file too large: {0} bytes (cap {1}). Pass max_bytes to override." -f $info.Length, $maxBytes)
    }

    $asDataUrl = $false
    if ($Arguments.ContainsKey('as_data_url')) { $asDataUrl = [bool]$Arguments['as_data_url'] }

    $ext  = $info.Extension.ToLowerInvariant().TrimStart('.')
    $mime = switch ($ext) {
        'png'  { 'image/png' }
        'jpg'  { 'image/jpeg' }
        'jpeg' { 'image/jpeg' }
        'webp' { 'image/webp' }
        'gif'  { 'image/gif' }
        'bmp'  { 'image/bmp' }
        default { 'application/octet-stream' }
    }

    $bytes = [System.IO.File]::ReadAllBytes($full)
    $b64   = [Convert]::ToBase64String($bytes)
    if ($asDataUrl) { $b64 = "data:${mime};base64,$b64" }

    Write-Log INFO ("encode_file_base64: {0} ({1} bytes -> {2} chars, mime={3}, data_url={4})" -f
        $full, $info.Length, $b64.Length, $mime, $asDataUrl)

    $summary = "Encoded $($info.Length) bytes from $full as base64 (mime=$mime, $($b64.Length) chars)."
    return @{
        content = @(
            @{ type = 'text'; text = $summary },
            @{ type = 'text'; text = $b64 }
        )
    }
}

# ── Tool: get_model_info ─────────────────────────────────────────────
# Curated view of sd-server's /sdcpp/v1/capabilities so the agent can
# discover which model is loaded, what mode it runs in, which inputs it
# accepts (ref_images / init_image / lora / hires), and what defaults
# will be applied to fields the caller omits in generate_image.
function Invoke-GetModelInfo {
    $caps = Invoke-SdJson -Method GET -Path '/sdcpp/v1/capabilities'

    # sd-server uses object-keyed "defaults" at top level for the current
    # mode; nested sample_params holds sampler/steps/guidance.
    $d  = $caps.defaults
    $sp = if ($d) { $d.sample_params } else { $null }
    $g  = if ($sp) { $sp.guidance } else { $null }

    # Models trained only on structured JSON captions (Ideogram4) need
    # generate_image's prompt_json instead of plain prompt — surface that
    # so the agent discovers it BEFORE wasting a render on a grey card.
    $wantsJson = [bool](([string]$caps.model.name) -match 'ideogram')

    $info = [ordered]@{
        model = [ordered]@{
            name = $caps.model.name
            stem = $caps.model.stem
            path = $caps.model.path
        }
        prompt_format   = if ($wantsJson) { 'structured-json' } else { 'plain-text' }
        current_mode    = $caps.current_mode
        supported_modes = @($caps.supported_modes)
        features        = $caps.features
        defaults        = [ordered]@{
            width           = $d.width
            height          = $d.height
            batch_count     = $d.batch_count
            seed            = $d.seed
            negative_prompt = $d.negative_prompt
            clip_skip       = $d.clip_skip
            sample_method   = if ($sp) { $sp.sample_method } else { $null }
            sample_steps    = if ($sp) { $sp.sample_steps } else { $null }
            scheduler       = if ($sp) { $sp.scheduler } else { $null }
            txt_cfg         = if ($g)  { $g.txt_cfg } else { $null }
            distilled_guidance = if ($g) { $g.distilled_guidance } else { $null }
            output_format   = $d.output_format
            strength        = $d.strength
            auto_resize_ref_image = $d.auto_resize_ref_image
        }
        limits   = $caps.limits
        samplers = @($caps.samplers)
        schedulers = @($caps.schedulers)
        output_formats = @($caps.output_formats)
        loras    = @($caps.loras | ForEach-Object { $_.name })
    }
    if ($wantsJson) {
        $info.prompt_format_note = 'This model is trained exclusively on structured JSON captions: plain-text prompts degenerate into a grey "blocked" card. Call generate_image with prompt_json (a real JSON object, not an escaped string) shaped {high_level_description, style_description: {aesthetics, lighting, photo, medium, color_palette: ["#hex",...]}, compositional_deconstruction: {canvas, background, layout, elements: [{type: "text"|"obj", desc},...]}}. Be exhaustively descriptive; spell any in-image text verbatim in a "text" element.'
    }

    Write-Log INFO ("get_model_info: model={0} mode={1}" -f $info.model.name, $info.current_mode)
    $json = $info | ConvertTo-Json -Depth 10
    return @{ content = @(@{ type = 'text'; text = $json }) }
}

# ── sd-server lifecycle helpers (shared by list/status/switch/stop) ──
# These read run\sd-server.state and the presets.ini that run-server.ps1
# writes / consumes. Liveness probes go through Invoke-SdJson, which
# already resolves the URL from the state file each call.

function Stop-SdServer {
    param([int]$TimeoutSec = 30)
    $statePath = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\run\sd-server.state"
    $state = Read-SdServerState -Path $statePath
    if (-not $state -or -not $state.pid) { return $false }
    if (-not (Test-SdServerAlive $state)) {
        # Dead — or a recycled PID now owned by an unrelated process, which
        # must NOT be Stop-Process'd. Either way the state file is stale.
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Log INFO "stopping sd-server (pid $($state.pid), preset '$($state.preset)')"
    try { Stop-Process -Id $state.pid -Force -ErrorAction Stop } catch {
        Write-Log WARN "Stop-Process failed: $($_.Exception.Message)"
    }
    # run-server.ps1's finally block removes the state file on exit.
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Test-Path $statePath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if (Test-Path $statePath) {
        Write-Log WARN "state file persisted past stop deadline; removing manually"
        Remove-Item $statePath -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Start-SdServer {
    param(
        [string]$PresetId,
        [int]$TimeoutSec = 180,
        $ProgressToken = $null,
        [double]$ProgressOffset = 0,
        # Forwarded to run-server.ps1's -ServerExe. switch_preset captures this
        # from the outgoing state file so a dev-mode sd-server (binary in
        # build\cmake-build\bin\) survives a preset switch — without it,
        # run-server.ps1 falls back to $PSScriptRoot\bin\sd-server.exe which
        # only exists in installed mode.
        [string]$ServerExe = ''
    )
    $runServer = Join-Path $PSScriptRoot "run-server.ps1"
    if (-not (Test-Path -LiteralPath $runServer)) {
        throw "run-server.ps1 not found at $runServer"
    }
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $pwshCmd) { throw "pwsh.exe not found on PATH" }

    $statePath = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\run\sd-server.state"
    # Start-Process -ArgumentList <array> does NOT quote elements that contain
    # spaces, so passing "C:\Program Files\...\run-server.ps1" via -File would
    # be split on the space and pwsh.exe would error with code 64. Build a
    # single command-line string with paths quoted explicitly. PresetId is a
    # validated INI section name; ServerExe is either inherited from the
    # outgoing state file or empty — both safe to wrap in double quotes.
    $argParts = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        ('-File "{0}"'    -f $runServer),
        ('-Preset "{0}"'  -f $PresetId),
        '-NonInteractive'
    )
    if (-not [string]::IsNullOrWhiteSpace($ServerExe)) {
        $argParts += ('-ServerExe "{0}"' -f $ServerExe)
    }
    $argString = $argParts -join ' '
    Write-Log INFO ("spawning run-server.ps1 detached: preset='{0}'{1}" -f
        $PresetId,
        $(if ($ServerExe) { " server_exe='$ServerExe'" } else { '' }))
    $proc = Start-Process -FilePath $pwshCmd.Source -ArgumentList $argString `
        -WindowStyle Hidden -PassThru

    $started  = Get-Date
    $deadline = $started.AddSeconds($TimeoutSec)
    $lastTick = -1

    while ($true) {
        if ($proc.HasExited -and -not (Test-Path $statePath)) {
            throw "run-server.ps1 exited (code $($proc.ExitCode)) before writing state file. Check logs\sd-server.log."
        }
        if (Test-Path $statePath) {
            # Get-SdServerBaseUrl resolves to the state file's host/port the
            # moment run-server.ps1 finishes writing it.
            try {
                $null = Invoke-SdJson -Method GET -Path '/sdcpp/v1/capabilities' -TimeoutSec 5
                Write-Log INFO "sd-server ready (preset='$PresetId', $(Get-SdServerBaseUrl))"
                return
            } catch {}
        }
        if ((Get-Date) -gt $deadline) {
            throw "sd-server did not become ready within ${TimeoutSec}s. Check logs\sd-server.log."
        }
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        if ($null -ne $ProgressToken -and $elapsed -ne $lastTick) {
            Send-RpcNotification 'notifications/progress' @{
                progressToken = $ProgressToken
                progress      = $ProgressOffset + $elapsed
                message       = "loading model... ${elapsed}s elapsed"
            }
            $lastTick = $elapsed
        }
        Start-Sleep -Milliseconds 500
    }
}

# ── Tool: server_status ──────────────────────────────────────────────
function Invoke-ServerStatus {
    $statePath = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\run\sd-server.state"
    $state = Read-SdServerState -Path $statePath
    if (-not $state) {
        $result = [ordered]@{ running = $false; reason = 'no state file (sd-server is not running)' }
        return @{ content = @(@{ type = 'text'; text = ($result | ConvertTo-Json -Depth 5) }) }
    }
    if (-not (Test-SdServerAlive $state)) {
        $result = [ordered]@{
            running     = $false
            reason      = "state file points at pid $($state.pid) which is no longer alive (or is no longer sd-server)"
            stale_state = $state
        }
        return @{ content = @(@{ type = 'text'; text = ($result | ConvertTo-Json -Depth 5) }) }
    }

    $ready   = $false
    $httpErr = $null
    try {
        $null = Invoke-SdJson -Method GET -Path '/sdcpp/v1/capabilities' -TimeoutSec 5
        $ready = $true
    } catch {
        $httpErr = $_.Exception.Message
    }

    $result = [ordered]@{
        running    = $true
        ready      = $ready
        pid        = $state.pid
        host       = $state.host
        port       = $state.port
        url        = Get-SdServerBaseUrl
        preset     = $state.preset
        server_exe = $state.server_exe
        started_at = $state.started_at
    }
    if (-not $ready) { $result.http_error = $httpErr }
    Write-Log INFO ("server_status: running=true ready={0} preset='{1}'" -f $ready, $state.preset)
    return @{ content = @(@{ type = 'text'; text = ($result | ConvertTo-Json -Depth 5) }) }
}

# ── Tool: list_presets ───────────────────────────────────────────────
function Invoke-ListPresets {
    $presetsPath = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config\presets.ini"
    $presets = @(Get-Presets -Path $presetsPath)

    $state = Read-SdServerState
    $activeId = $null
    if (Test-SdServerAlive $state) {
        $activeId = [string]$state.preset
    }

    $list = @()
    foreach ($p in $presets) {
        $entry = [ordered]@{ id = $p.Id; active = ($p.Id -eq $activeId) }
        # Surface the most useful preset keys; agent can re-run get_model_info
        # on the active preset for full detail.
        foreach ($k in 'model','diffusion-model','vae','llm','t5xxl','clip_l','clip_g',
                       'sampler','scheduler','steps','width','height','cfg-scale','guidance',
                       'type','max-vram') {
            if ($p.Keys.ContainsKey($k)) { $entry[$k] = $p.Keys[$k] }
        }
        $list += $entry
    }

    $info = [ordered]@{
        presets = $list
        active  = $activeId
        path    = $presetsPath
    }
    Write-Log INFO ("list_presets: {0} preset(s), active='{1}'" -f $list.Count, $activeId)
    return @{ content = @(@{ type = 'text'; text = ($info | ConvertTo-Json -Depth 5) }) }
}

# ── Tool: stop_server ────────────────────────────────────────────────
function Invoke-StopServer {
    $state = Read-SdServerState
    if (-not (Test-SdServerAlive $state)) {
        Write-Log INFO "stop_server: nothing to stop"
        return @{ content = @(@{ type = 'text'; text = 'sd-server is not running. No action taken.' }) }
    }
    $pidWas    = $state.pid
    $presetWas = $state.preset
    Stop-SdServer | Out-Null
    $msg = "Stopped sd-server (pid $pidWas, preset '$presetWas')."
    Write-Log INFO "stop_server: $msg"
    return @{ content = @(@{ type = 'text'; text = $msg }) }
}

# ── Tool: switch_preset ──────────────────────────────────────────────
# Stops the current sd-server (if any), spawns run-server.ps1 with the
# requested preset detached (-WindowStyle Hidden -NonInteractive), and
# waits for /sdcpp/v1/capabilities to respond. Model load is the slow
# part — expect 10-30s for big diffusion models.
function Invoke-SwitchPreset {
    param([hashtable]$Arguments, $ProgressToken = $null)

    if (-not $Arguments -or
        -not $Arguments.ContainsKey('preset') -or
        [string]::IsNullOrWhiteSpace([string]$Arguments['preset'])) {
        throw "missing required argument: preset"
    }
    $presetId   = [string]$Arguments['preset']
    $timeoutSec = if ($Arguments.ContainsKey('timeout_sec')) { [int]$Arguments['timeout_sec'] } else { 180 }

    $presetsPath = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config\presets.ini"
    $presets = @(Get-Presets -Path $presetsPath)
    $target  = $presets | Where-Object { $_.Id -eq $presetId } | Select-Object -First 1
    if (-not $target) {
        $known = ($presets | ForEach-Object { $_.Id }) -join ', '
        throw "preset '$presetId' not found in $presetsPath. Known: $known"
    }

    $current = Read-SdServerState
    if ((Test-SdServerAlive $current) -and ([string]$current.preset -eq $presetId)) {
        Write-Log INFO "switch_preset: '$presetId' already active (pid $($current.pid)); no-op"
        return @{ content = @(@{ type = 'text'; text = "Preset '$presetId' is already loaded (pid $($current.pid)). No action taken." }) }
    }

    # Capture the outgoing instance's sd-server.exe path before Stop-SdServer
    # tears the state file down. Inheriting it keeps a dev-mode build (binary
    # under build\cmake-build\bin\) usable across a preset switch. State files
    # written by pre-server_exe versions of run-server.ps1 lack the field —
    # warn so the silent fall-through to run-server.ps1's default lookup is
    # at least observable in the log.
    $inheritedExe = ''
    if (Test-SdServerAlive $current) {
        if ($current.server_exe) {
            $inheritedExe = [string]$current.server_exe
        } else {
            Write-Log WARN "outgoing state file has no server_exe field; relying on run-server.ps1's default lookup"
        }
    }

    $started = Get-Date
    if ($null -ne $ProgressToken) {
        Send-RpcNotification 'notifications/progress' @{
            progressToken = $ProgressToken; progress = 0
            message       = "stopping current sd-server..."
        }
    }
    $stopped = Stop-SdServer

    $offset = [int]((Get-Date) - $started).TotalSeconds
    if ($null -ne $ProgressToken) {
        Send-RpcNotification 'notifications/progress' @{
            progressToken = $ProgressToken; progress = $offset
            message       = "starting sd-server with preset '$presetId'..."
        }
    }
    Start-SdServer -PresetId $presetId -TimeoutSec $timeoutSec `
        -ProgressToken $ProgressToken -ProgressOffset $offset `
        -ServerExe $inheritedExe

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    $msg = if ($stopped) {
        "Switched preset to '$presetId' (stop+start took ${elapsed}s)."
    } else {
        "Started sd-server with preset '$presetId' (took ${elapsed}s)."
    }
    Write-Log INFO $msg
    return @{ content = @(@{ type = 'text'; text = $msg }) }
}

# ── Tool registry ────────────────────────────────────────────────────
$Tools = @(
    @{
        name        = 'generate_image'
        description = 'Start an image generation on the local sd-server. ASYNC by default (fire-and-forget): submits the job and returns a job_id immediately — then poll check_image_job with that job_id for progress and to receive the finished image (renders can take 10s-many minutes). Pass wait=true to instead block until the image is ready and return it inline (streams notifications/progress while it works). Requires sd-server to be running. Exactly one of `prompt` (plain text) or `prompt_json` (structured caption object) is required — check get_model_info.prompt_format to pick: models trained on JSON captions (Ideogram4) need prompt_json and reject plain text.'
        inputSchema = @{
            type     = 'object'
            properties = @{
                prompt          = @{ type = 'string';  description = 'Positive prompt, plain text. For models whose get_model_info.prompt_format is "structured-json" (Ideogram4) use prompt_json instead — a plain-text prompt makes those models render a grey "blocked" card and this tool refuses it up front.' }
                prompt_json     = @{ type = 'object';  description = 'Structured JSON caption for caption-native models (get_model_info.prompt_format = "structured-json", currently Ideogram4). Pass a REAL JSON object — the MCP server serializes it compactly into the prompt string, so never hand-escape it into `prompt`. Shape: {high_level_description: string, style_description: {aesthetics, lighting, photo, medium, color_palette: ["#hex",...]}, compositional_deconstruction: {canvas, background, layout, elements: [{type: "text"|"obj", desc: string},...]}}. Write it exhaustively descriptive — name every object explicitly; spell any in-image text verbatim in a "text" element (these models excel at typography). Takes precedence over prompt when both are set. Harmless but pointless on plain-text models.' }
                negative_prompt = @{ type = 'string';  description = 'Negative prompt. Note: Flux/Chroma-era models ignore this.' }
                width           = @{ type = 'integer'; default = 1024; minimum = 64 }
                height          = @{ type = 'integer'; default = 1024; minimum = 64 }
                steps           = @{ type = 'integer'; description = 'Sampling steps. Defaults to the active preset.' }
                cfg_scale       = @{ type = 'number';  description = 'Classifier-free guidance scale (SDXL-era models).' }
                guidance        = @{ type = 'number';  description = 'Distilled guidance scale (Flux/Chroma-era models).' }
                sampler         = @{ type = 'string';  description = 'Sampler: euler, euler_a, dpm++2m, etc. Defaults to the preset.' }
                scheduler       = @{ type = 'string';  description = 'Noise scheduler: discrete, karras, ays, etc. Defaults to the preset.' }
                flow_shift      = @{ type = 'number';  description = 'Flow-model sigma shift (SD3/Wan/Ideogram4 etc.). Defaults to the server (auto). NB: sd.cpp auto for Ideogram4 is 1.0 while reference ComfyUI workflows use 5.' }
                lora_multiplier = @{ type = 'number';  description = 'Override the multiplier of the preset-injected LoRA(s) for this request only (applies to all entries; 0 disables them). Defaults to the value in the preset INI lora key (e.g. 0.6). No effect when the active preset has no lora key.' }
                seed            = @{ type = 'integer'; description = 'Random seed. Omit or set -1 for random.' }
                batch_count     = @{ type = 'integer'; default = 1; minimum = 1; maximum = 8 }
                output_format   = @{ type = 'string';  enum = @('png','jpeg','webp'); default = 'jpeg'; description = 'JPEG keeps Claude context cost low; PNG for pixel-perfect.' }
                output_compression = @{ type = 'integer'; default = 90; minimum = 1; maximum = 100; description = 'JPEG/WebP quality. Ignored for PNG.' }
                init_image      = @{ type = 'string';  description = 'Image to denoise from (img2img). STRONGLY PREFER an absolute file path (.png/.jpg/.webp) — the MCP server loads and base64-encodes the file locally. Raw base64 / data: URLs are accepted but will silently truncate for any image bigger than a few KB because the model cannot reproduce them verbatim across a tool call. Do NOT chain `encode_file_base64` into this argument. Use the `strength` arg to control how much is preserved.' }
                ref_images      = @{
                    type        = 'array'
                    items       = @{ type = 'string' }
                    description = 'Reference images for multi-reference-aware models (Flux Kontext, OmniGen, etc.). STRONGLY PREFER absolute file paths — the MCP server loads each file from disk and encodes it locally. Raw base64 / data: URLs are accepted but break in practice on anything larger than a thumbnail because the model truncates the string when emitting the tool call. Do NOT chain `encode_file_base64` into this argument. Has no effect on plain SDXL/Flux dev models. Pair with prompts that mention what each reference depicts.'
                }
                strength             = @{ type = 'number';  minimum = 0; maximum = 1; description = 'Denoise strength for img2img (0 = keep init_image, 1 = ignore it). Only used when init_image is set. sd.cpp default is 0.75.' }
                auto_resize_ref_image = @{ type = 'boolean'; description = 'If true, ref_images are resized to match output width/height. Defaults to the sd-server preset.' }
                save_path            = @{ type = 'string';  description = 'Optional absolute path to also write the rendered image to disk. Parent directory is auto-created. If batch_count > 1, the filename stem is suffixed with _001, _002, ... before the extension. Extension is honoured as-is — match it to output_format (jpeg/png/webp) yourself. Relative paths resolve against the MCP server CWD, which is unpredictable — pass absolute paths. A sidecar `<stem>.json` is written next to the image(s) containing the flat request params (prompt, dimensions, sampler/scheduler, steps, cfg_scale/guidance, seed, init_image/ref_images paths, per-image seeds reported by sd-server) so the call can be replayed later. In fire-and-forget mode (wait omitted/false), setting save_path also starts a detached background collector that saves the finished image to this path automatically — so a long render is not lost even if you never poll check_image_job (sd-server otherwise discards a completed result after 600s).' }
                return_inline        = @{ type = 'boolean'; description = 'Whether to also embed the rendered image(s) as inline base64 MCP content. Default: true when save_path is not set (current behavior), false when save_path is set (avoids blowing up context for batches you only want on disk). Set true with save_path to get both. In async mode this preference is stashed with the job and honoured by check_image_job when it delivers the result.' }
                wait                 = @{ type = 'boolean'; default = $false; description = 'If false (default), this tool returns a job_id immediately (fire-and-forget) and you fetch the image later with check_image_job — best for long renders so the call does not block. When save_path is set, a detached collector also saves the result to disk automatically, so the image survives even if you poll late or not at all. If true, the tool blocks until the render finishes and returns the image inline (no collector needed), streaming notifications/progress when a progressToken is supplied.' }
            }
        }
    },
    @{
        name        = 'encode_file_base64'
        description = 'Read a local binary file and return its base64 representation as a text block. WARNING: do NOT use this to stage images for generate_image — the model cannot reliably emit a multi-KB base64 string verbatim when feeding the result back into another tool call, so generate_image will fail with "invalid ref_images". Pass the raw file path to generate_image instead; the MCP server encodes it internally without round-tripping through the model. This tool is only useful for small files (a few KB) or when the caller genuinely needs the base64 surfaced into the conversation. Capped at 25 MB raw by default.'
        inputSchema = @{
            type     = 'object'
            required = @('path')
            properties = @{
                path        = @{ type = 'string';  description = 'Absolute path to the file to encode.' }
                as_data_url = @{ type = 'boolean'; default = $false; description = 'If true, prefix output with `data:<mime>;base64,` so it can be dropped straight into HTML/CSS or APIs that expect a data URL.' }
                max_bytes   = @{ type = 'integer'; default = 26214400; minimum = 1; description = 'Raw-file size cap. Files larger than this are rejected to keep model context affordable.' }
            }
        }
    },
    @{
        name        = 'get_model_info'
        description = 'Return a curated snapshot of the model currently loaded by sd-server: name/stem/path, prompt_format ("plain-text" or "structured-json" — the latter means generate_image needs prompt_json, not prompt), current mode (img_gen / vid_gen), supported features (init_image, ref_images, lora, hires, ...), the defaults that will be applied to fields you omit in generate_image (sampler, steps, txt_cfg, distilled_guidance, width/height, ...), dimension limits, and the lists of supported samplers / schedulers / output_formats / loras. Call this before generate_image when you need to know which knobs are meaningful for the active model (e.g. Flux models ignore negative_prompt, only some accept ref_images, Ideogram4 requires structured JSON captions).'
        inputSchema = @{
            type       = 'object'
            properties = @{}
        }
    },
    @{
        name        = 'server_status'
        description = 'Report whether sd-server is currently running and ready. Reads the run/sd-server.state file written by run-server.ps1, then probes /sdcpp/v1/capabilities to verify the process is actually serving HTTP (a fresh process may still be loading the model). Returns running/ready flags plus pid, host, port, url, active preset, server_exe path, and started_at timestamp. Call this before generate_image when you''re not sure sd-server is up, or as a sanity check after switch_preset.'
        inputSchema = @{
            type       = 'object'
            properties = @{}
        }
    },
    @{
        name        = 'list_presets'
        description = 'List all configured model presets from presets.ini, with their key parameters (model paths, sampler, steps, dimensions, guidance, memory knobs). Marks which preset is currently loaded (active=true). Use this to discover what presets are available before calling switch_preset.'
        inputSchema = @{
            type       = 'object'
            properties = @{}
        }
    },
    @{
        name        = 'switch_preset'
        description = 'Stop the current sd-server and restart it with a different preset (or just start it, if nothing was running). The preset name must match an [section] in presets.ini — call list_presets first if unsure. This is a SLOW operation: model load takes 10-30 seconds for big diffusion models (Flux, SDXL), and the previous model is fully unloaded first since sd-server holds one model per process. Returns a no-op message if the requested preset is already active. Progress notifications are streamed when the client supplies a progressToken.'
        inputSchema = @{
            type     = 'object'
            required = @('preset')
            properties = @{
                preset      = @{ type = 'string';  description = 'Preset id, matching a [section] header in presets.ini. Use list_presets to discover.' }
                timeout_sec = @{ type = 'integer'; default = 180; minimum = 10; description = 'How long to wait for sd-server to come up and respond to /sdcpp/v1/capabilities. Bump for very large models or slow disks.' }
            }
        }
    },
    @{
        name        = 'stop_server'
        description = 'Stop the running sd-server (Stop-Process by pid from the state file). Returns a no-op message if nothing was running. Note: when the user originally launched sd-server via the "stable-diffusion.cpp" Start Menu shortcut, stopping it from here closes their foreground window — confirm intent before calling this if a human is using the web UI.'
        inputSchema = @{
            type       = 'object'
            properties = @{}
        }
    },
    @{
        name        = 'check_image_job'
        description = 'Check an async generate_image job by its job_id and, when finished, receive the rendered image. This is how you consult progress for a fire-and-forget generate_image call. While the job is queued/generating it returns {status, queue_position, elapsed_sec, done:false} — poll again. When done it returns the image(s) (inline base64 and/or written to the save_path you gave generate_image, plus the params sidecar) exactly as wait=true would have. A failed/cancelled job comes back as an error with sd-server''s reason. Call with NO job_id to list the jobs this server is currently tracking. Completed/failed jobs are forgotten once fetched, so fetch each job_id once you see done:true.'
        inputSchema = @{
            type       = 'object'
            properties = @{
                job_id = @{ type = 'string'; description = 'The job_id returned by generate_image (async mode). Omit to instead list all jobs this server is locally tracking.' }
            }
        }
    },
    @{
        name        = 'cancel_image_job'
        description = 'Cancel a queued or in-progress async generate_image job by its job_id (asks sd-server to abort it) and drop the local tracking record. A job that already finished or never existed is reported back, not treated as an error. Use check_image_job (no job_id) to discover outstanding job ids.'
        inputSchema = @{
            type     = 'object'
            required = @('job_id')
            properties = @{
                job_id = @{ type = 'string'; description = 'The job_id returned by generate_image (async mode) to cancel.' }
            }
        }
    }
)

# ── JSON-RPC framing ─────────────────────────────────────────────────
function New-RpcResult { param($Id, $Result) @{ jsonrpc = '2.0'; id = $Id; result = $Result } }
function New-RpcError  {
    param($Id, [int]$Code, [string]$Message, $Data = $null)
    $err = @{ code = $Code; message = $Message }
    if ($null -ne $Data) { $err.data = $Data }
    return @{ jsonrpc = '2.0'; id = $Id; error = $err }
}

function Invoke-Tool {
    param([string]$Name, [hashtable]$Arguments, $ProgressToken = $null)
    switch ($Name) {
        'generate_image'     { return Invoke-GenerateImage    -Arguments $Arguments -ProgressToken $ProgressToken }
        'check_image_job'    { return Invoke-CheckImageJob    -Arguments $Arguments }
        'cancel_image_job'   { return Invoke-CancelImageJob   -Arguments $Arguments }
        'encode_file_base64' { return Invoke-EncodeFileBase64 -Arguments $Arguments }
        'get_model_info'     { return Invoke-GetModelInfo }
        'server_status'      { return Invoke-ServerStatus }
        'list_presets'       { return Invoke-ListPresets }
        'switch_preset'      { return Invoke-SwitchPreset    -Arguments $Arguments -ProgressToken $ProgressToken }
        'stop_server'        { return Invoke-StopServer }
        default              { throw "unknown tool: $Name" }
    }
}

function Invoke-RpcRequest {
    param([hashtable]$Request)
    $method = [string]$Request['method']
    $id     = if ($Request.ContainsKey('id')) { $Request['id'] } else { $null }
    $params = if ($Request.ContainsKey('params') -and $Request['params']) { $Request['params'] } else { @{} }

    switch ($method) {
        'initialize' {
            # Echo client's protocolVersion when present — safest negotiation strategy.
            $proto = if ($params['protocolVersion']) { [string]$params['protocolVersion'] } else { '2025-06-18' }
            return New-RpcResult $id @{
                protocolVersion = $proto
                serverInfo      = @{ name = 'stable-diffusion-cpp'; version = $script:McpServerVersion }
                capabilities    = @{ tools = @{} }
            }
        }
        'notifications/initialized' { return $null }
        'notifications/cancelled'   { return $null }
        'ping'                       { return New-RpcResult $id @{} }
        'tools/list'                 { return New-RpcResult $id @{ tools = $Tools } }
        'tools/call' {
            $toolName = [string]$params['name']
            # MCP: an unknown tool name is a PROTOCOL error (-32602), not a
            # tool-execution failure — don't fold it into isError content.
            if (@($Tools | ForEach-Object { $_.name }) -notcontains $toolName) {
                return New-RpcError $id -32602 "unknown tool: $toolName"
            }
            $toolArgs = @{}
            if ($params.ContainsKey('arguments') -and $params['arguments']) {
                $toolArgs = [hashtable]$params['arguments']
            }
            # MCP: clients opt into progress streaming by including
            # _meta.progressToken in the call; we echo it back in every
            # notifications/progress so the client can correlate.
            $progressToken = $null
            if ($params.ContainsKey('_meta') -and $params['_meta'] -and $params['_meta']['progressToken']) {
                $progressToken = $params['_meta']['progressToken']
            }
            try {
                $r = Invoke-Tool -Name $toolName -Arguments $toolArgs -ProgressToken $progressToken
                return New-RpcResult $id $r
            } catch {
                Write-Log ERROR "tool '$toolName' failed: $($_.Exception.Message)"
                # MCP convention: tool errors come back as a successful RPC
                # result with isError=true so the model sees the failure text.
                return New-RpcResult $id @{
                    content = @(@{ type = 'text'; text = "Error: $($_.Exception.Message)" })
                    isError = $true
                }
            }
        }
        default {
            if ($null -eq $id) { return $null }
            return New-RpcError $id -32601 "method not found: $method"
        }
    }
}

# ── Background collector mode ─────────────────────────────────────────
# Entered when this script is invoked with -CollectJob <id> (spawned detached
# by Start-CollectorProcess). NOT the MCP stdio server: it polls that one job to
# a terminal state and, on completion, persists the result to disk through
# Complete-ImageJob — independent of any MCP client, so a save_path render is
# never lost to sd-server's 600s completed-result TTL even if the client polls
# late or not at all. Then it exits. All HTTP / meta / delivery logic is reused
# from the functions above; the only thing it cannot do is return inline (no
# client), which is why it is spawned only for save_path jobs.
#
# Contention with a manual check_image_job for the same id is benign: whoever
# reads the meta first saves the file (Complete-ImageJob is idempotent on the
# same path) and removes the meta; the other finds the meta gone and exits /
# degrades to inline-only. The image is never lost in any ordering.
if (-not [string]::IsNullOrWhiteSpace($CollectJob)) {
    Write-Log INFO ("collector started for job {0} (poll={1}s, max={2}s, PID {3})" -f $CollectJob, $CollectPollSec, $CollectMaxSec, $PID)
    $deadline = (Get-Date).AddSeconds($CollectMaxSec)
    $fails    = 0
    $maxFails = 10            # consecutive lost-contact polls before giving up (~2.5 min @15s)
    while ($true) {
        Start-Sleep -Seconds $CollectPollSec
        if ((Get-Date) -gt $deadline) {
            Write-Log WARN ("collector for {0} hit {1}s backstop; leaving meta for manual recovery" -f $CollectJob, $CollectMaxSec)
            break
        }
        try {
            $job   = Invoke-SdJson -Method GET -Path "/sdcpp/v1/jobs/$CollectJob" -TimeoutSec 10
            $fails = 0
        } catch {
            # 404 (forgotten) / 410 (expired+purged): nothing left to collect.
            # Any OTHER failure (connection refused, timeout) is transient — the
            # job may still be rendering — so tolerate a few before giving up.
            $httpStatus = $null
            if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                $httpStatus = [int]$_.Exception.Response.StatusCode
            } elseif ($_.Exception.Data -and $_.Exception.Data.Contains('StatusCode')) {
                $httpStatus = [int]$_.Exception.Data['StatusCode']
            }
            if ($httpStatus -eq 404 -or $httpStatus -eq 410) {
                Write-Log WARN ("collector: job {0} gone from sd-server (HTTP {1}) — stopping" -f $CollectJob, $httpStatus)
                Remove-JobMeta $CollectJob
                break
            }
            $fails++
            Write-Log WARN ("collector poll {0}/{1} failed for {2}: {3}" -f $fails, $maxFails, $CollectJob, $_.Exception.Message)
            if ($fails -ge $maxFails) {
                Write-Log WARN ("collector for {0} lost contact ({1} consecutive failures); leaving meta for manual recovery" -f $CollectJob, $maxFails)
                break
            }
            continue
        }

        $status = [string]$job.status
        if ($status -in @('queued', 'generating')) { continue }

        if ($status -eq 'completed') {
            $meta = Read-JobMeta $CollectJob
            if ($null -eq $meta) {
                # The client's own check_image_job already collected + removed it.
                Write-Log INFO ("collector: job {0} already collected by client — nothing to do" -f $CollectJob)
                break
            }
            try {
                $null = Complete-ImageJob -Job $job -Meta $meta
                Write-Log INFO ("collector: job {0} completed and saved to disk" -f $CollectJob)
            } catch {
                Write-Log ERROR ("collector: failed to deliver job {0}: {1}" -f $CollectJob, $_.Exception.Message)
            }
            Remove-JobMeta $CollectJob
            break
        }

        # failed / cancelled / any other terminal status
        $errMsg = if ($job.error) { "$($job.error.code): $($job.error.message)" } else { 'unknown error' }
        Write-Log WARN ("collector: job {0} {1} — {2}" -f $CollectJob, $status, $errMsg)
        Remove-JobMeta $CollectJob
        break
    }
    Write-Log INFO ("collector for {0} exiting" -f $CollectJob)
    exit 0
}

# ── Main loop ────────────────────────────────────────────────────────
Write-Log INFO "stable-diffusion-cpp MCP server starting (PID $PID)"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
# Redirected stdin defaults to the OEM codepage on Windows; the MCP client
# sends UTF-8, so without this any non-ASCII prompt (accents, em-dashes,
# emoji) arrives mojibake'd and is forwarded to sd-server corrupted. Guarded:
# the setter can throw when no console is attached.
try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
$stdin  = [Console]::In
$stdout = [Console]::Out

while ($true) {
    $line = $stdin.ReadLine()
    if ($null -eq $line) { Write-Log INFO "stdin closed, exiting"; break }
    if ($line.Length -eq 0) { continue }

    $req = $null
    try {
        $req = $line | ConvertFrom-Json -AsHashtable -Depth 100
    } catch {
        Write-Log ERROR "malformed JSON: $($_.Exception.Message)"
        $resp = New-RpcError $null -32700 "parse error: $($_.Exception.Message)"
        $stdout.WriteLine(($resp | ConvertTo-Json -Compress -Depth 100))
        $stdout.Flush()
        continue
    }

    try {
        $resp = Invoke-RpcRequest -Request $req
    } catch {
        Write-Log ERROR "handler crashed: $($_.Exception.Message)"
        # $req may be valid JSON yet not an object (a batch array, a scalar)
        # — indexing it with ['id'] would throw AGAIN here and kill the
        # whole server loop on a single malformed message.
        $rid = if ($req -is [hashtable]) { $req['id'] } else { $null }
        $resp = New-RpcError $rid -32603 "internal error: $($_.Exception.Message)"
    }

    if ($null -eq $resp) { continue }
    $stdout.WriteLine(($resp | ConvertTo-Json -Compress -Depth 100))
    $stdout.Flush()
}
