# Shared helpers for the runtime scripts under %ProgramFiles%\stable-diffusion.cpp.
# Dot-sourced by config-server.ps1, config-model.ps1, and run-server.ps1.
#
# Currently exposes a small INI parser/writer for
# %LOCALAPPDATA%\stable-diffusion.cpp\config\server.ini (machine-wide sd-server
# settings). Per-model presets live in presets.ini and are managed inline by
# config-model.ps1; this helper does not touch that file.
#
# Encoding: server.ini is UTF-8 without BOM (consistent with presets.ini).
# NSIS reads it via -DumpIni in config-server.ps1, which transcodes to
# UTF-16 LE for GetPrivateProfileStringW.

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
