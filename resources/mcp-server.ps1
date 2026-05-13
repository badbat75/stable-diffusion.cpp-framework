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

function Invoke-GenerateImage {
    param([hashtable]$Arguments, $ProgressToken = $null)

    if (-not $Arguments -or
        -not $Arguments.ContainsKey('prompt') -or
        [string]::IsNullOrWhiteSpace([string]$Arguments['prompt'])) {
        throw "missing required argument: prompt"
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

    # save_path: optional disk dump. When set, default is to NOT also stream
    # the image inline (return_inline opts back in). When unset, default
    # remains "inline only" so existing callers are unaffected.
    $savePath = if ($Arguments.ContainsKey('save_path')) { [string]$Arguments['save_path'] } else { '' }
    $returnInline = if ($Arguments.ContainsKey('return_inline')) {
        [bool]$Arguments['return_inline']
    } else {
        [string]::IsNullOrWhiteSpace($savePath)
    }

    $savedPaths = @()
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
    }

    # annotations hint to MCP clients that the image is meant for the user
    # to see (audience=user, high priority) — by-the-book per MCP spec. Note:
    # claude.ai web is reported to ignore the hint and not render inline
    # regardless (modelcontextprotocol/specification issue #238); Claude Code
    # honours it. Doesn't hurt to send it.
    $imageContents = @()
    if ($returnInline) {
        foreach ($img in $images) {
            $b64 = [string]$img.b64_json
            $imageContents += @{
                type        = 'image'
                data        = $b64
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
    if (-not $returnInline) {
        $summary += " (Inline image omitted; pass return_inline=true to also embed.)"
    }
    Write-Log INFO ("job {0} completed in {1}s — {2} image(s), inline={3}, saved={4}" -f
        $jobId, $elapsed, $images.Count, $returnInline, $savedPaths.Count)

    return @{ content = @(@{ type = 'text'; text = $summary }) + $imageContents }
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
                init_image      = @{ type = 'string';  description = 'Image to denoise from (img2img). STRONGLY PREFER an absolute file path (.png/.jpg/.webp) — the MCP server loads and base64-encodes the file locally. Raw base64 / data: URLs are accepted but will silently truncate for any image bigger than a few KB because the model cannot reproduce them verbatim across a tool call. Do NOT chain `encode_file_base64` into this argument. Use the `strength` arg to control how much is preserved.' }
                ref_images      = @{
                    type        = 'array'
                    items       = @{ type = 'string' }
                    description = 'Reference images for multi-reference-aware models (Flux Kontext, OmniGen, etc.). STRONGLY PREFER absolute file paths — the MCP server loads each file from disk and encodes it locally. Raw base64 / data: URLs are accepted but break in practice on anything larger than a thumbnail because the model truncates the string when emitting the tool call. Do NOT chain `encode_file_base64` into this argument. Has no effect on plain SDXL/Flux dev models. Pair with prompts that mention what each reference depicts.'
                }
                strength             = @{ type = 'number';  minimum = 0; maximum = 1; description = 'Denoise strength for img2img (0 = keep init_image, 1 = ignore it). Only used when init_image is set. sd.cpp default is 0.75.' }
                auto_resize_ref_image = @{ type = 'boolean'; description = 'If true, ref_images are resized to match output width/height. Defaults to the sd-server preset.' }
                save_path            = @{ type = 'string';  description = 'Optional absolute path to also write the rendered image to disk. Parent directory is auto-created. If batch_count > 1, the filename stem is suffixed with _001, _002, ... before the extension. Extension is honoured as-is — match it to output_format (jpeg/png/webp) yourself. Relative paths resolve against the MCP server CWD, which is unpredictable — pass absolute paths.' }
                return_inline        = @{ type = 'boolean'; description = 'Whether to also embed the rendered image(s) as inline base64 MCP content. Default: true when save_path is not set (current behavior), false when save_path is set (avoids blowing up context for batches you only want on disk). Set true with save_path to get both.' }
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
        'encode_file_base64' { return Invoke-EncodeFileBase64 -Arguments $Arguments }
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
