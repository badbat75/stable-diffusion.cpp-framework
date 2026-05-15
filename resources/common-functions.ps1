# Shared helpers for the runtime scripts under %ProgramFiles%\stable-diffusion.cpp.
# Dot-sourced by run-server.ps1 and mcp-server.ps1. After the sd-config GUI/CLI
# replaced the PowerShell configuration wizards, this file's surface shrank to
# just the read-side helpers — INI writes happen exclusively in Rust now.
#
# Exposes:
#   - Read-ServerIni                              — server.ini [Server] parser
#   - Get-Presets                                 — presets.ini → @({ Id, Keys })
#   - Read-SdServerState                          — run\sd-server.state JSON reader
#   - ConvertTo-IntOrNull / FloatOrNull / BoolOrNull — INI-string coercion
#
# Encoding: server.ini and presets.ini are UTF-8 without BOM. sd-server.state
# is UTF-8 JSON.

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
# Turn INI string values into typed values for further processing. All return
# $null on blank / unparseable input rather than throwing.

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
