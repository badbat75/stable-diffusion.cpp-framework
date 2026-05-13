# MCP server for stable-diffusion.cpp (PowerShell, stdio transport).
# Bridges Claude Code (or any MCP client) to a running sd-server instance.
#
# Protocol: JSON-RPC 2.0, newline-delimited, over stdin/stdout.
# All diagnostic logging goes to stderr + a log file — never stdout, which
# is reserved for the JSON-RPC stream.
#
# Reads sd-server's host/port from
#   %LOCALAPPDATA%\stable-diffusion.cpp\config\server.ini
# Requires sd-server to already be running (start it via run-server.ps1
# or the "stable-diffusion.cpp" Start Menu shortcut).
#
# Tools exposed:
#   generate_image  — txt2img via /sdcpp/v1/img_gen (native async endpoint)
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
    [int]   $RequestTimeoutSec = 600
)

$ErrorActionPreference = 'Stop'

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
$srvRaw  = Read-ServerIni -Path $ServerIni
$srvHost = if ($srvRaw['Hostname']) { $srvRaw['Hostname'] } else { 'localhost' }
$srvPort = if ($srvRaw['Port'])     { [int]$srvRaw['Port'] } else { 1234 }
# When sd-server binds to all interfaces we still talk to it on loopback.
if ($srvHost -eq '0.0.0.0') { $srvHost = '127.0.0.1' }
$baseUrl = "http://${srvHost}:${srvPort}"
Write-Log INFO "sd-server endpoint: $baseUrl  (config: $ServerIni)"

# ── HTTP helper ──────────────────────────────────────────────────────
function Invoke-SdJson {
    param([string]$Method, [string]$Path, $Body)
    $url    = $baseUrl + $Path
    $params = @{
        Uri         = $url
        Method      = $Method
        TimeoutSec  = $RequestTimeoutSec
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body        = ($Body | ConvertTo-Json -Depth 100 -Compress)
    }
    return Invoke-RestMethod @params
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
function Invoke-GenerateImage {
    param([hashtable]$Arguments, $ProgressToken = $null)

    if (-not $Arguments -or
        -not $Arguments.ContainsKey('prompt') -or
        [string]::IsNullOrWhiteSpace([string]$Arguments['prompt'])) {
        throw "missing required argument: prompt"
    }

    # Translate flat MCP args → sd-server's nested gen_params schema.
    # Top-level: prompt, negative_prompt, width, height, batch_count, seed.
    # Nested under sample_params: sample_steps, sample_method, scheduler,
    #   plus guidance.txt_cfg / guidance.distilled_guidance.
    $sampleParams = @{}
    $guidance     = @{}

    if ($Arguments.ContainsKey('steps'))       { $sampleParams.sample_steps  = [int]$Arguments['steps'] }
    if ($Arguments.ContainsKey('sampler'))     { $sampleParams.sample_method = [string]$Arguments['sampler'] }
    if ($Arguments.ContainsKey('scheduler'))   { $sampleParams.scheduler     = [string]$Arguments['scheduler'] }
    if ($Arguments.ContainsKey('cfg_scale'))   { $guidance.txt_cfg            = [double]$Arguments['cfg_scale'] }
    if ($Arguments.ContainsKey('guidance'))    { $guidance.distilled_guidance = [double]$Arguments['guidance'] }
    if ($guidance.Count -gt 0)                 { $sampleParams.guidance      = $guidance }

    $body = @{
        prompt             = [string]$Arguments['prompt']
        width              = if ($Arguments.ContainsKey('width'))       { [int]$Arguments['width'] }       else { 1024 }
        height             = if ($Arguments.ContainsKey('height'))      { [int]$Arguments['height'] }      else { 1024 }
        batch_count        = if ($Arguments.ContainsKey('batch_count')) { [int]$Arguments['batch_count'] } else { 1 }
        output_format      = if ($Arguments.ContainsKey('output_format')) { [string]$Arguments['output_format'] } else { 'jpeg' }
        output_compression = if ($Arguments.ContainsKey('output_compression')) { [int]$Arguments['output_compression'] } else { 90 }
    }
    if ($Arguments.ContainsKey('negative_prompt')) { $body.negative_prompt = [string]$Arguments['negative_prompt'] }
    if ($Arguments.ContainsKey('seed'))            { $body.seed            = [int64]$Arguments['seed'] }
    if ($sampleParams.Count -gt 0)                 { $body.sample_params   = $sampleParams }

    $promptPreview = $body.prompt.Substring(0, [Math]::Min(60, $body.prompt.Length))
    Write-Log INFO ("submit img_gen: '{0}...' {1}x{2} batch={3} fmt={4}" -f
        $promptPreview, $body.width, $body.height, $body.batch_count, $body.output_format)

    $submit = Invoke-SdJson -Method POST -Path '/sdcpp/v1/img_gen' -Body $body
    $jobId  = $submit.id
    if (-not $jobId) {
        throw "sd-server did not return a job id (response: $($submit | ConvertTo-Json -Compress -Depth 5))"
    }
    Write-Log INFO "job submitted: $jobId"

    # Emit an initial progress event so the client gets immediate feedback
    # even before sd-server transitions out of "queued".
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
    while ($true) {
        Start-Sleep -Milliseconds $PollIntervalMs
        $job = Invoke-SdJson -Method GET -Path $pollUrl

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

    $images = @($job.result.images)
    if ($images.Count -eq 0) { throw "job $jobId completed but returned no images" }

    $mime = switch ([string]$job.result.output_format) {
        'png'  { 'image/png' }
        'jpeg' { 'image/jpeg' }
        'webp' { 'image/webp' }
        default { 'application/octet-stream' }
    }

    # annotations hint to MCP clients that the image is meant for the user
    # to see (audience=user, high priority) — by-the-book per MCP spec. Note:
    # claude.ai web is reported to ignore the hint and not render inline
    # regardless (modelcontextprotocol/specification issue #238); Claude Code
    # honours it. Doesn't hurt to send it.
    $imageContents = @()
    foreach ($img in $images) {
        $b64 = [string]$img.b64_json
        $imageContents += @{
            type        = 'image'
            data        = $b64
            mimeType    = $mime
            annotations = @{ audience = @('user'); priority = 0.9 }
        }
    }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    $summary = "Generated $($images.Count) image(s) in ${elapsed}s."
    Write-Log INFO "job $jobId completed in ${elapsed}s — $($images.Count) image(s) returned"

    return @{ content = @(@{ type = 'text'; text = $summary }) + $imageContents }
}

# ── Tool registry ────────────────────────────────────────────────────
$Tools = @(
    @{
        name        = 'generate_image'
        description = 'Generate an image with stable-diffusion.cpp via the local sd-server. Returns the rendered image inline as base64 (no on-disk copy). Requires sd-server to be running.'
        inputSchema = @{
            type     = 'object'
            required = @('prompt')
            properties = @{
                prompt          = @{ type = 'string';  description = 'Positive prompt.' }
                negative_prompt = @{ type = 'string';  description = 'Negative prompt. Note: Flux/Chroma-era models ignore this.' }
                width           = @{ type = 'integer'; default = 1024; minimum = 64 }
                height          = @{ type = 'integer'; default = 1024; minimum = 64 }
                steps           = @{ type = 'integer'; description = 'Sampling steps. Defaults to the active preset.' }
                cfg_scale       = @{ type = 'number';  description = 'Classifier-free guidance scale (SDXL-era models).' }
                guidance        = @{ type = 'number';  description = 'Distilled guidance scale (Flux/Chroma-era models).' }
                sampler         = @{ type = 'string';  description = 'Sampler: euler, euler_a, dpm++2m, etc. Defaults to the preset.' }
                scheduler       = @{ type = 'string';  description = 'Noise scheduler: discrete, karras, ays, etc. Defaults to the preset.' }
                seed            = @{ type = 'integer'; description = 'Random seed. Omit or set -1 for random.' }
                batch_count     = @{ type = 'integer'; default = 1; minimum = 1; maximum = 8 }
                output_format   = @{ type = 'string';  enum = @('png','jpeg','webp'); default = 'jpeg'; description = 'JPEG keeps Claude context cost low; PNG for pixel-perfect.' }
                output_compression = @{ type = 'integer'; default = 90; minimum = 1; maximum = 100; description = 'JPEG/WebP quality. Ignored for PNG.' }
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
        'generate_image' { return Invoke-GenerateImage -Arguments $Arguments -ProgressToken $ProgressToken }
        default          { throw "unknown tool: $Name" }
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
                serverInfo      = @{ name = 'stable-diffusion-cpp'; version = '0.1.0' }
                capabilities    = @{ tools = @{} }
            }
        }
        'notifications/initialized' { return $null }
        'notifications/cancelled'   { return $null }
        'ping'                       { return New-RpcResult $id @{} }
        'tools/list'                 { return New-RpcResult $id @{ tools = $Tools } }
        'tools/call' {
            $toolName = [string]$params['name']
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

# ── Main loop ────────────────────────────────────────────────────────
Write-Log INFO "stable-diffusion-cpp MCP server starting (PID $PID)"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
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
        $resp = New-RpcError $req['id'] -32603 "internal error: $($_.Exception.Message)"
    }

    if ($null -eq $resp) { continue }
    $stdout.WriteLine(($resp | ConvertTo-Json -Compress -Depth 100))
    $stdout.Flush()
}
