# Per-model preset builder for sd-server.
#
# Operates directly on %LOCALAPPDATA%\stable-diffusion.cpp\config\presets.ini —
# the file consumed by `run-server.ps1` to translate one preset section into
# sd-server CLI args at launch time. Each [section] in the INI is one preset;
# the section name is the id shown in the launcher's model picker.
#
# This script edits exactly one section at a time. Other sections in the file —
# including any custom keys you've hand-added, comments, and ordering — are
# preserved byte-for-byte. The section being edited is rewritten in full from
# the wizard's answers, so any custom keys IN THAT SECTION will be lost; if you
# want exotic flags on a preset, set them up via the wizard first, then add
# the exotic keys by hand and don't re-run the wizard for that preset.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "common-functions.ps1")

$configDir   = Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\config"
$serverPath  = Join-Path $configDir "server.ini"
$presetsPath = Join-Path $configDir "presets.ini"

if (-not (Test-Path $serverPath)) {
    Write-Host ""
    Write-Host "  No server.ini at $serverPath" -ForegroundColor Yellow
    Write-Host "  Run config-server.ps1 first to set up sd-server." -ForegroundColor Yellow
    Write-Host ""
    return
}
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$serverCfg = Read-ServerIni -Path $serverPath

# Prompt helpers (Read-*Default) and INI section parsing (Get-Presets) live
# in common-functions.ps1; ConvertTo-*OrNull helpers below do too.

# Stable filesystem-safe id per model: basename without extension, without
# multi-shard suffix, with non-alphanumerics collapsed to underscores.
function Get-ModelId {
    param([string]$ModelPath)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ModelPath)
    $base = $base -replace '-\d{5}-of-\d{5}$', ''
    return ($base -replace '[^a-zA-Z0-9._-]+', '_')
}

Write-Host ""
Write-Host "── stable-diffusion.cpp model preset ──" -ForegroundColor Cyan
Write-Host ""

# 1) Models directory
$defaultModelsDir = if ($serverCfg['ModelsDir']) { $serverCfg['ModelsDir'] } else { Join-Path $env:USERPROFILE ".stable-diffusion.cpp\models" }
$modelsDir = $null
while (-not $modelsDir) {
    $reply = Read-Host "Models directory [$defaultModelsDir]"
    if (-not $reply) { $reply = $defaultModelsDir }
    if (Test-Path $reply -PathType Container) {
        $modelsDir = (Resolve-Path $reply).Path
    } else {
        Write-Host "  Directory not found. Try again or Ctrl+C to abort." -ForegroundColor Yellow
    }
}

# 2) Scan .gguf / .safetensors files (recursive). For multi-shard models,
#    only show the first shard.
Write-Host ""
Write-Host "Scanning $modelsDir for .gguf / .safetensors models..." -ForegroundColor DarkGray
$models = Get-ChildItem -Path $modelsDir -Include @('*.gguf', '*.safetensors') -Recurse -File `
    | Where-Object { $_.Name -notmatch '-\d{5}-of-\d{5}\.(gguf|safetensors)$' -or $_.Name -match '-00001-of-\d{5}\.(gguf|safetensors)$' } `
    | Sort-Object FullName

if ($models.Count -eq 0) {
    throw "No .gguf or .safetensors files found under $modelsDir."
}

# 3) Read existing presets so already-configured models get a `*` marker.
#    Matching is by the file path stored in each section's `diffusion-model`
#    or `model` key — not by section name — so user-renamed sections still
#    light up the marker (and feed defaults into the wizard below).
$sections = @(Get-Presets -Path $presetsPath)

function Get-NormalizedPath {
    param([string]$Path)
    if (-not $Path) { return $null }
    try { return ([System.IO.Path]::GetFullPath($Path)).ToLowerInvariant() }
    catch { return $Path.ToLowerInvariant() }
}

$sectionsByPath = @{}
foreach ($s in $sections) {
    $sk = $s.Keys
    $p = if ($sk['diffusion-model']) { $sk['diffusion-model'] } elseif ($sk['model']) { $sk['model'] } else { $null }
    $np = Get-NormalizedPath $p
    if ($np -and -not $sectionsByPath.ContainsKey($np)) { $sectionsByPath[$np] = $s }
}

Write-Host ""
Write-Host "Available models:" -ForegroundColor Cyan
for ($i = 0; $i -lt $models.Count; $i++) {
    $sizeGb  = [math]::Round($models[$i].Length / 1GB, 2)
    $relPath = $models[$i].FullName.Substring($modelsDir.Length).TrimStart('\', '/')
    $np      = Get-NormalizedPath $models[$i].FullName
    $marker  = if ($sectionsByPath.ContainsKey($np)) { '*' } else { ' ' }
    Write-Host ("  [{0,2}]{1} {2}  ({3} GB)" -f ($i + 1), $marker, $relPath, $sizeGb)
}
Write-Host ""
Write-Host "  (* = already a preset section in presets.ini)" -ForegroundColor DarkGray

# 4) Selection
$selected = $null
while (-not $selected) {
    $reply = Read-Host "`nSelect model [1-$($models.Count)]"
    [int]$idx = 0
    if ([int]::TryParse($reply, [ref]$idx) -and $idx -ge 1 -and $idx -le $models.Count) {
        $selected = $models[$idx - 1]
    } else {
        Write-Host "  Invalid selection." -ForegroundColor Yellow
    }
}

$modelId = Get-ModelId $selected.FullName
$selectedPath = Get-NormalizedPath $selected.FullName
$existingSection = if ($sectionsByPath.ContainsKey($selectedPath)) {
    $sectionsByPath[$selectedPath]
} else {
    $sections | Where-Object { $_.Id -eq $modelId } | Select-Object -First 1
}
# Preserve a hand-renamed section name instead of overwriting it with the
# filename-derived id.
if ($existingSection) { $modelId = $existingSection.Id }
$cur = if ($existingSection) { $existingSection.Keys } else { @{} }

# Model type drives whether the picked file is written to `model` (-m, full
# all-in-one bundle) or `diffusion-model` (--diffusion-model, standalone UNet
# needing external VAE / text encoder). sd-server requires exactly one of the
# two — populating both was the source of confusion in earlier presets.
#
# Default: if the existing section already has a non-empty `diffusion-model`,
# stay in standalone mode; otherwise default to standalone for new presets
# (matches Flux / Flux2 / SD3 / Wan / Qwen-Image, the common modern case).
$curDiffusion = if ($cur.ContainsKey('diffusion-model')) { $cur['diffusion-model'] } else { $null }
$curModel     = if ($cur.ContainsKey('model'))           { $cur['model'] }           else { $null }
$modelTypeDefault =
    if ($curDiffusion) { 'standalone' }
    elseif ($curModel) { 'allinone' }
    else { 'standalone' }

# Sub-model paths
$curVae       = if ($cur.ContainsKey('vae'))             { $cur['vae'] }             else { $null }
$curLlm       = if ($cur.ContainsKey('llm'))             { $cur['llm'] }             else { $null }
$curT5xxl     = if ($cur.ContainsKey('t5xxl'))           { $cur['t5xxl'] }           else { $null }
$curClipL     = if ($cur.ContainsKey('clip_l'))          { $cur['clip_l'] }          else { $null }
$curClipG     = if ($cur.ContainsKey('clip_g'))          { $cur['clip_g'] }          else { $null }
$curLoraDir   = if ($cur.ContainsKey('lora-model-dir'))  { $cur['lora-model-dir'] }  else { $null }
$curEmbdDir   = if ($cur.ContainsKey('embd-dir'))        { $cur['embd-dir'] }        else { $null }
# Memory / perf knobs
$curWeightType= if ($cur.ContainsKey('type'))            { $cur['type'] }            else { $null }
$curOffload   = ConvertTo-BoolOrNull  $cur['offload-to-cpu']
$curMmap      = ConvertTo-BoolOrNull  $cur['mmap']
$curFa        = ConvertTo-BoolOrNull  $cur['fa']
$curDiffFa    = ConvertTo-BoolOrNull  $cur['diffusion-fa']
$curClipOnCpu = ConvertTo-BoolOrNull  $cur['clip-on-cpu']
$curVaeOnCpu  = ConvertTo-BoolOrNull  $cur['vae-on-cpu']
$curVaeTiling = ConvertTo-BoolOrNull  $cur['vae-tiling']
$curMaxVram   = ConvertTo-FloatOrNull $cur['max-vram']
# Default generation params (the web UI lets users override per-request)
$curSampler   = if ($cur.ContainsKey('sampler')) { $cur['sampler'] } else { $null }
$curSteps     = ConvertTo-IntOrNull   $cur['steps']
$curCfg       = ConvertTo-FloatOrNull $cur['cfg-scale']
$curGuidance  = ConvertTo-FloatOrNull $cur['guidance']
$curWidth     = ConvertTo-IntOrNull   $cur['width']
$curHeight    = ConvertTo-IntOrNull   $cur['height']

# 5) Prompt for all per-model parameters
Write-Host ""
Write-Host "Selected: $($selected.FullName)" -ForegroundColor Green
Write-Host "Preset id: $modelId" -ForegroundColor Green
Write-Host "Press Enter to accept the default; type '-' to unset an optional field." -ForegroundColor DarkGray
Write-Host ""

Write-Host "── Model type ──" -ForegroundColor Cyan
Write-Host "  [allinone]    SD 1.x / SDXL single-file .safetensors with UNet + VAE + text" -ForegroundColor DarkGray
Write-Host "                encoder bundled together. Maps to sd-server's -m / --model." -ForegroundColor DarkGray
Write-Host "  [standalone]  Flux / Flux2 / SD3 / Wan / Qwen-Image / Chroma — diffusion-only" -ForegroundColor DarkGray
Write-Host "                weights that need an external VAE + text encoder. Maps to" -ForegroundColor DarkGray
Write-Host "                sd-server's --diffusion-model." -ForegroundColor DarkGray
Write-Host ""
$modelType = Read-EnumDefault "Model type" $modelTypeDefault @('allinone','standalone')

Write-Host ""
Write-Host "── Sub-model paths ──" -ForegroundColor Cyan
if ($modelType -eq 'standalone') {
    Write-Host "  Required set depends on the diffusion architecture:" -ForegroundColor DarkGray
    Write-Host "    *  --vae      SD3, Flux, Flux2, Wan, Qwen-Image" -ForegroundColor DarkGray
    Write-Host "    *  --llm      Flux2 (mistral-small-3.2), Qwen-Image (qwen2.5vl), Z-Image (qwen3)" -ForegroundColor DarkGray
    Write-Host "    *  --t5xxl    SD3, Flux, Wan, Chroma" -ForegroundColor DarkGray
    Write-Host "    *  --clip_l   SD3, Flux" -ForegroundColor DarkGray
    Write-Host "    *  --clip_g   SD3" -ForegroundColor DarkGray
} else {
    Write-Host "  All-in-one bundles normally embed their VAE / text encoder — leave these unset." -ForegroundColor DarkGray
    Write-Host "  Override only if you're swapping in a separate VAE or text encoder file." -ForegroundColor DarkGray
}
Write-Host ""
$vae            = Read-StringDefault " * VAE (--vae)"                                    $curVae       -AllowUnset
$llm            = Read-StringDefault " * LLM text encoder (--llm)"                       $curLlm       -AllowUnset
$t5xxl          = Read-StringDefault " * T5-XXL text encoder (--t5xxl)"                  $curT5xxl     -AllowUnset
$clipL          = Read-StringDefault " * CLIP-L text encoder (--clip_l)"                 $curClipL     -AllowUnset
$clipG          = Read-StringDefault " * CLIP-G text encoder (--clip_g)"                 $curClipG     -AllowUnset
$loraDir        = Read-StringDefault "   LoRA model directory (--lora-model-dir)"        $curLoraDir   -AllowUnset
$embdDir        = Read-StringDefault "   Embeddings directory (--embd-dir)"              $curEmbdDir   -AllowUnset

Write-Host ""
Write-Host "── Memory / performance ──" -ForegroundColor Cyan
$weightType = Read-EnumDefault "Weight type (--type)" $(if ($curWeightType) { $curWeightType } else { '' }) @('f32','f16','q8_0','q5_1','q5_0','q4_1','q4_0','q2_K','q3_K','q4_K') -AllowUnset
$offload    = Read-BoolDefault "Offload weights to CPU (--offload-to-cpu)" $(if ($null -ne $curOffload) { $curOffload } else { $false })
$mmap       = Read-BoolDefault "Memory-map weights (--mmap)" $(if ($null -ne $curMmap) { $curMmap } else { $true })
$fa         = Read-BoolDefault "Flash Attention everywhere (--fa)" $(if ($null -ne $curFa) { $curFa } else { $false })
$diffFa     = Read-BoolDefault "Flash Attention in diffusion only (--diffusion-fa)" $(if ($null -ne $curDiffFa) { $curDiffFa } else { $true })
$clipOnCpu  = Read-BoolDefault "Keep CLIP on CPU (--clip-on-cpu)" $(if ($null -ne $curClipOnCpu) { $curClipOnCpu } else { $false })
$vaeOnCpu   = Read-BoolDefault "Keep VAE on CPU (--vae-on-cpu)" $(if ($null -ne $curVaeOnCpu) { $curVaeOnCpu } else { $false })
$vaeTiling  = Read-BoolDefault "VAE tiled decode (--vae-tiling; recommended for high-res output)" $(if ($null -ne $curVaeTiling) { $curVaeTiling } else { $false })
$maxVram    = Read-FloatDefault "Max VRAM budget in GiB (--max-vram; 0 = unlimited)" $curMaxVram -AllowUnset

Write-Host ""
Write-Host "── Default generation params (web UI can override per request) ──" -ForegroundColor Cyan
$sampler = Read-EnumDefault "Sampler (--sampler)" $(if ($curSampler) { $curSampler } else { 'euler_a' }) `
    @('euler_a','euler','heun','dpm2','dpm++2s_a','dpm++2m','dpm++2mv2','lcm','ipndm','ipndm_v','ddim_trailing','tcd')
$steps   = Read-IntDefault   "Steps (--steps)"          $(if ($curSteps)  { $curSteps }  else { 20 })  -Min 1 -Max 200
$cfg     = Read-FloatDefault "CFG scale (--cfg-scale)"  $(if ($null -ne $curCfg) { $curCfg }    else { 7.0 })
$guidance= Read-FloatDefault "Distilled guidance (--guidance; Flux/Flux2 only, default 3.5)" $curGuidance -AllowUnset
$width   = Read-IntDefault   "Width (-W)"               $(if ($curWidth)  { $curWidth }  else { 512 }) -Min 64 -Max 8192
$height  = Read-IntDefault   "Height (-H)"              $(if ($curHeight) { $curHeight } else { 512 }) -Min 64 -Max 8192

# 6) Build the new section text. Set values are emitted as live keys; unset
#    optional values are emitted as commented placeholders so the user can
#    discover them later.
function Emit-Setting {
    param([System.Text.StringBuilder]$Sb, [string]$Key, $Value, [string]$Example = $null)
    if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) {
        if ($Example) { [void]$Sb.AppendLine("; $Key = $Example") }
        return
    }
    [void]$Sb.AppendLine("$Key = $Value")
}
function Emit-Bool {
    param([System.Text.StringBuilder]$Sb, [string]$Key, $Value)
    if ($null -eq $Value) { return }
    [void]$Sb.AppendLine("$Key = $(if ($Value) { 'true' } else { 'false' })")
}

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("[$modelId]")
[void]$sb.AppendLine("; Generated by config-model.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm').")
[void]$sb.AppendLine('; Re-running the wizard rewrites this section; hand-edits to OTHER sections')
[void]$sb.AppendLine('; in this file are preserved. To add exotic sd-server flags, edit by hand and')
[void]$sb.AppendLine('; do not re-run the wizard for this preset.')
[void]$sb.AppendLine('')
if ($modelType -eq 'allinone') {
    [void]$sb.AppendLine('; All-in-one model bundle (-m). SD 1.x / SDXL single-file checkpoint with')
    [void]$sb.AppendLine('; UNet + VAE + text encoder bundled together. Sub-model paths below are')
    [void]$sb.AppendLine('; normally unused for this type.')
    [void]$sb.AppendLine("model = $($selected.FullName)")
} else {
    [void]$sb.AppendLine('; Standalone diffusion model (--diffusion-model). Requires an external')
    [void]$sb.AppendLine('; VAE and the architecture-specific text encoder(s) below.')
    [void]$sb.AppendLine("diffusion-model = $($selected.FullName)")
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('; Sub-model paths')
Emit-Setting $sb 'vae'             $vae
Emit-Setting $sb 'llm'             $llm
Emit-Setting $sb 't5xxl'           $t5xxl
Emit-Setting $sb 'clip_l'          $clipL
Emit-Setting $sb 'clip_g'          $clipG
Emit-Setting $sb 'lora-model-dir'  $loraDir
Emit-Setting $sb 'embd-dir'        $embdDir
[void]$sb.AppendLine('')
[void]$sb.AppendLine('; Memory / performance')
Emit-Setting $sb 'type'            $weightType
Emit-Bool    $sb 'offload-to-cpu'  $offload
Emit-Bool    $sb 'mmap'            $mmap
Emit-Bool    $sb 'fa'              $fa
Emit-Bool    $sb 'diffusion-fa'    $diffFa
Emit-Bool    $sb 'clip-on-cpu'     $clipOnCpu
Emit-Bool    $sb 'vae-on-cpu'      $vaeOnCpu
Emit-Bool    $sb 'vae-tiling'      $vaeTiling
Emit-Setting $sb 'max-vram'        $maxVram '8.0'
[void]$sb.AppendLine('')
[void]$sb.AppendLine('; Default generation params (web UI can override per request)')
Emit-Setting $sb 'sampler'         $sampler
Emit-Setting $sb 'steps'           $steps
Emit-Setting $sb 'cfg-scale'       $cfg
Emit-Setting $sb 'guidance'        $guidance
Emit-Setting $sb 'width'           $width
Emit-Setting $sb 'height'          $height

$newSection = $sb.ToString().TrimEnd("`r", "`n") + "`r`n"

# 7) Section-preserving write: replace existing [modelId] section, or append
#    a new one, leaving the rest of the file untouched.
$existingText = if (Test-Path $presetsPath) { Get-Content -Path $presetsPath -Raw -Encoding UTF8 } else { '' }
if (-not $existingText) { $existingText = '' }

$escapedId = [regex]::Escape($modelId)
$existingMatch = [regex]::Match($existingText, "(?m)^\[$escapedId\][\s\S]*?(?=^\[|\z)")
if ($existingMatch.Success) {
    $before = $existingText.Substring(0, $existingMatch.Index)
    $after  = $existingText.Substring($existingMatch.Index + $existingMatch.Length)
    # If another section follows, insert a blank-line separator before it.
    $sep    = if ($after -ne '') { "`r`n" } else { '' }
    $newText = $before + $newSection + $sep + $after
} else {
    if ($existingText.Length -gt 0) {
        $existingText = $existingText.TrimEnd("`r", "`n") + "`r`n`r`n"
    }
    $newText = $existingText + $newSection
}

[System.IO.File]::WriteAllText($presetsPath, $newText, [System.Text.UTF8Encoding]::new($false))

# 8) Update server.ini's ModelsDir pointer
Set-ServerIniField -Path $serverPath -Key 'ModelsDir' -Value $modelsDir

Write-Host ""
if ($existingMatch.Success) {
    Write-Host "Updated preset: $modelId" -ForegroundColor Green
} else {
    Write-Host "Added preset: $modelId" -ForegroundColor Green
}
Write-Host "  File: $presetsPath"
Write-Host "  Edit it directly to tweak values, add exotic flags, or remove a preset."
Write-Host "  run-server.ps1 will offer this preset in its model picker at launch."
Write-Host ""
