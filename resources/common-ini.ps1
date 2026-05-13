# Shared helpers for the runtime scripts under %ProgramFiles%\stable-diffusion.cpp.
# Dot-sourced by config-generate.ps1, config-model.ps1, and run-generate.ps1.
#
# Exposes lightweight INI parser/writers for config.ini and models.ini:
#   Read-ConfigIni     — parse the [Settings] section into a hashtable of strings
#   Set-ConfigField    — replace one key in [Settings] while preserving comments, order, sections
#   Read-ModelEntry    — parse a named model section into a hashtable of strings
#   Write-ModelSection — write/overwrite one named model section to models.ini

function Read-ConfigIni {
    param([string]$Path)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $inSettings = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $inSettings = ($Matches[1].Trim() -ieq 'Settings')
            continue
        }
        if (-not $inSettings) { continue }
        if ($t -match '^([^=]+?)\s*=\s*(.*)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            # Strip trailing ` ; ...` inline comment but tolerate `;` inside paths.
            if ($value -match '^(.*?)\s+[;#]\s.*$') { $value = $Matches[1].Trim() }
            $result[$key] = $value
        }
    }
    return $result
}

function Set-ConfigField {
    param([string]$Path, [string]$Key, [string]$Value)
    $newLine = "$Key = $Value"

    if (-not (Test-Path -LiteralPath $Path)) {
        $content = "[Settings]`r`n$newLine`r`n"
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $content) { $content = '' }

    $headerRx  = [regex]'(?m)^\[Settings\]\s*$'
    $headerM   = $headerRx.Match($content)
    if (-not $headerM.Success) {
        $sep           = if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { "`r`n" } else { '' }
        $content       = $content + $sep + "[Settings]`r`n$newLine`r`n"
        [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
        return
    }

    $sectionStart       = $headerM.Index + $headerM.Length
    $rest                 = $content.Substring($sectionStart)
    $nextSectionPosition  = ([regex]'(?m)^\[').Match($rest).Index
    $sectionEndPosition   = if ($nextSectionPosition -ge 0) { $sectionStart + $nextSectionPosition } else { $content.Length }
    $section              = $content.Substring($sectionStart, $sectionEndPosition - $sectionStart)

    $keyRx = "(?m)^(\s*){0}\s*=.*$" -f [regex]::Escape($Key)
    if ([regex]::IsMatch($section, $keyRx)) {
        $newSection = [regex]::Replace($section, $keyRx, $newLine, 1)
    } else {
        $trimmed          = $section.TrimEnd("`r", "`n")
        $newSection       = $trimmed + "`r`n$newLine`r`n"
        if ($nextSectionPosition -ge 0) { $newSection += "`r`n" }
    }

    $newContent = $content.Substring(0, $sectionStart) + $newSection + $content.Substring($sectionEndPosition)
    [System.IO.File]::WriteAllText($Path, $newContent, [System.Text.UTF8Encoding]::new($false))
}

function Read-ModelEntry {
    param([string]$Path, [string]$SectionName)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $content  = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    # Match the section header followed by key=value lines until next section or EOF.
    $pattern = "(?sm)^\[{0}\](.*?)^(?:\[|\z)" -f [regex]::Escape($SectionName)
    $match   = [regex]::Match($content, $pattern)
    if (-not $match.Success) { return $result }

    $section = $match.Groups[1].Value
    foreach ($line in ($section -split "`r?`n")) {
        $t          = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^([^=]+?)\s*=\s*(.*)$') {
            $key   = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            if ($value -match '^(.*?)\s+[;#]\s.*$') { $value = $Matches[1].Trim() }
            $result[$Key] = $value
        }
    }
    return $result
}

function Write-ModelSection {
    param([string]$Path, [string]$SectionName, [hashtable]$Data)
    # Build the full section block.
    $lines  = @("[{0}]" -f $SectionName)
    foreach ($entry in $Data.GetEnumerator()) {
        $lines += "{0} = {1}" -f $entry.Key, $entry.Value
    }
    $fullSection = ($lines -join "`r`n") + "`r`n"

    if (-not (Test-Path -LiteralPath $Path)) {
        [System.IO.File]::WriteAllText($Path, $fullSection, [System.Text.UTF8Encoding]::new($false))
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $content) { $content = ''; }
    # Remove the old section entirely, replace it.
    $pattern      = "(?sm)^\[{0}\].*?(?:\z|\n\[)" -f [regex]::Escape($SectionName)
    $cleanContent = [regex]::Replace($content, $pattern, '', 1)
    # Ensure blank line separates from any preceding content.
    if ($cleanContent.EndsWith("`r`n") -or $cleanContent.EndsWith("`n")) {
        $newContent = "{0}{1}" -f $cleanContent, $fullSection
    } else {
        $newContent = "{0}`r`n{1}" -f $cleanContent, $fullSection
    }
    [System.IO.File]::WriteAllText($Path, $newContent, [System.Text.UTF8Encoding]::new($false))
}
