# Shared helpers for the runtime scripts under %ProgramFiles%\stable-diffusion.cpp.
# Dot-sourced by config-server.ps1, config-model.ps1, run-server.ps1, and
# mcp-server.ps1.
#
# Exposes:
#   - Read-ServerIni / Set-ServerIniField  — server.ini parser + targeted writer
#   - Get-Presets                          — presets.ini parser
#   - Read-SdServerState                   — run\sd-server.state JSON reader
#   - ConvertTo-IntOrNull / FloatOrNull / BoolOrNull — INI-string coercion
#   - Read-IntDefault / FloatDefault / BoolDefault / StringDefault / EnumDefault
#       — interactive prompts with defaults (used by the config writers)
#
# Encoding: server.ini and presets.ini are UTF-8 without BOM. sd-server.state
# is UTF-8 JSON. NSIS reads server.ini via -DumpIni in config-server.ps1,
# which transcodes to UTF-16 LE for GetPrivateProfileStringW.

function Read-ServerIni {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $inSection = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $inSection = ($Matches[1].Trim() -ieq 'Server')
            continue
        }
        if (-not $inSection) { continue }
        if ($t -match '^([^=]+?)\s*=\s*(.*)$') {
            $key = $Matches[1].Trim()
            $val = $Matches[2].Trim()
            # Strip an inline ` ; ...` comment, but tolerate `;` inside paths.
            if ($val -match '^(.*?)\s+[;#]\s.*$') { $val = $Matches[1].Trim() }
            $result[$key] = $val
        }
    }
    return $result
}

# Replace one key inside the [Server] section while preserving every other
# line (comments, key order, other sections). Used by config-model.ps1 to
# update ModelsDir without rewriting the rest of the file.
function Set-ServerIniField {
    param([string]$Path, [string]$Key, [string]$Value)

    $newLine = "$Key = $Value"

    if (-not (Test-Path -LiteralPath $Path)) {
        $content = "[Server]`r`n$newLine`r`n"
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $content) { $content = '' }

    $headerRx = [regex]'(?m)^\[Server\]\s*$'
    $headerMatch = $headerRx.Match($content)
    if (-not $headerMatch.Success) {
        $sep = if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { "`r`n" } else { '' }
        $content = $content + $sep + "[Server]`r`n$newLine`r`n"
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
        return
    }

    $sectionStart = $headerMatch.Index + $headerMatch.Length
    $rest = $content.Substring($sectionStart)
    $nextSection = [regex]::Match($rest, '(?m)^\[')
    $sectionEnd = if ($nextSection.Success) { $sectionStart + $nextSection.Index } else { $content.Length }
    $section = $content.Substring($sectionStart, $sectionEnd - $sectionStart)

    $keyRx = "(?m)^(\s*)$([regex]::Escape($Key))\s*=.*$"
    if ([regex]::IsMatch($section, $keyRx)) {
        $newSection = [regex]::Replace($section, $keyRx, $newLine, 1)
    } else {
        $trimmed = $section.TrimEnd("`r", "`n")
        $newSection = $trimmed + "`r`n$newLine`r`n"
        if ($nextSection.Success) { $newSection += "`r`n" }
    }

    $newContent = $content.Substring(0, $sectionStart) + $newSection + $content.Substring($sectionEnd)
    [System.IO.File]::WriteAllText($Path, $newContent, [System.Text.UTF8Encoding]::new($false))
}

# Parse presets.ini into an array of pscustomobject { Id, Keys }. Shared by
# run-server.ps1 (picker + preset lookup) and mcp-server.ps1 (list_presets /
# switch_preset). Same INI dialect as Read-ServerIni: `; ` and `# ` start
# comments, both at line start and inline after whitespace.
function Get-Presets {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $text) { return @() }
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

# Read %LOCALAPPDATA%\stable-diffusion.cpp\run\sd-server.state. Returns the
# parsed JSON (PSCustomObject with pid/host/port/preset/server_exe/started_at)
# or $null if the file is missing or unparseable. Caller is responsible for
# liveness check via Get-Process -Id $state.pid — a present file does NOT
# guarantee sd-server is still alive (e.g. if run-server.ps1 was killed
# uncleanly before its finally block could remove the file).
function Read-SdServerState {
    param([string]$Path = (Join-Path $env:LOCALAPPDATA "stable-diffusion.cpp\run\sd-server.state"))
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

# ── Type coercion ────────────────────────────────────────────────────
# Used by run-server.ps1, config-server.ps1, and config-model.ps1 to
# turn the string values pulled out of INI files into typed values
# (int / double / bool) for further processing. All return $null on
# blank / unparseable input rather than throwing.

function ConvertTo-IntOrNull {
    param($v)
    if ([string]::IsNullOrWhiteSpace("$v")) { return $null }
    $p = 0
    if ([int]::TryParse("$v", [ref]$p)) { return $p }
    return $null
}

function ConvertTo-FloatOrNull {
    param($v)
    if ([string]::IsNullOrWhiteSpace("$v")) { return $null }
    $p = [double]0
    if ([double]::TryParse("$v", [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$p)) { return $p }
    return $null
}

function ConvertTo-BoolOrNull {
    param($v)
    if ($v -eq 'true')  { return $true }
    if ($v -eq 'false') { return $false }
    return $null
}

# ── Interactive prompt helpers ───────────────────────────────────────
# Used by config-server.ps1 and config-model.ps1. Each prompts with a
# default ([shown]), accepts Enter to keep the default, and accepts `-`
# to unset optional fields when -AllowUnset is set. Loop until a valid
# value is entered; invalid input prints a hint and re-prompts.

function Read-IntDefault {
    param([string]$Prompt, $Default, [int]$Min = 0, [int]$Max = [int]::MaxValue, [switch]$AllowUnset)
    while ($true) {
        $shown = if ($null -eq $Default) { 'unset' } else { "$Default" }
        $reply = Read-Host "$Prompt [$shown]"
        if (-not $reply) { return $Default }
        if ($AllowUnset -and $reply -eq '-') { return $null }
        [int]$parsed = 0
        if ([int]::TryParse($reply, [ref]$parsed) -and $parsed -ge $Min -and $parsed -le $Max) {
            return $parsed
        }
        Write-Host "  Invalid value (expected $Min-$Max$(if ($AllowUnset) { ' or `-` to unset' }))." -ForegroundColor Yellow
    }
}

function Read-FloatDefault {
    param([string]$Prompt, $Default, [switch]$AllowUnset)
    while ($true) {
        $shown = if ($null -eq $Default) { 'unset' } else { "$Default" }
        $reply = Read-Host "$Prompt [$shown]"
        if (-not $reply) { return $Default }
        if ($AllowUnset -and $reply -eq '-') { return $null }
        [double]$parsed = 0
        if ([double]::TryParse($reply, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return $parsed
        }
        Write-Host "  Invalid number." -ForegroundColor Yellow
    }
}

function Read-BoolDefault {
    param([string]$Prompt, [bool]$Default)
    while ($true) {
        $shown = if ($Default) { 'Y/n' } else { 'y/N' }
        $reply = Read-Host "$Prompt [$shown]"
        if (-not $reply) { return $Default }
        if ($reply -match '^[yY]') { return $true }
        if ($reply -match '^[nN]') { return $false }
        Write-Host "  Invalid (y/n)." -ForegroundColor Yellow
    }
}

function Read-StringDefault {
    param([string]$Prompt, $Default, [switch]$AllowUnset)
    $shown = if (-not $Default) { 'unset' } else { $Default }
    $reply = Read-Host "$Prompt [$shown]"
    if (-not $reply) { return $Default }
    if ($AllowUnset -and $reply -eq '-') { return $null }
    return $reply
}

function Read-EnumDefault {
    param([string]$Prompt, [string]$Default, [string[]]$Choices, [switch]$AllowUnset)
    $list = $Choices -join '/'
    while ($true) {
        $shown = if ($null -eq $Default -or $Default -eq '') { 'unset' } else { $Default }
        $reply = Read-Host "$Prompt ($list) [$shown]"
        if (-not $reply) { return $Default }
        if ($AllowUnset -and $reply -eq '-') { return $null }
        if ($Choices -contains $reply) { return $reply }
        Write-Host "  Invalid (one of: $list)." -ForegroundColor Yellow
    }
}
