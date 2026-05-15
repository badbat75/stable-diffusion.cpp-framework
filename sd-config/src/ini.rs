// Minimal INI parser / writer that preserves comments and section order.
//
// Tracks the same dialect as resources/common-functions.ps1 (Read-ServerIni
// + Get-Presets): `;` and `#` start comments, both at line start and inline
// after whitespace. Values are trimmed; an inline ` ; ...` comment after a
// value is stripped while preserving `;` inside paths (only ` ; ` or ` # `
// with surrounding whitespace counts).
//
// `replace_section` rewrites a single section in place while leaving every
// other section in the file byte-for-byte intact — the contract sd-config
// relies on so hand-edits to non-touched presets survive a GUI save.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Default, Clone)]
pub struct Section {
    pub id: String,
    pub keys: BTreeMap<String, String>,
}

/// Parse all sections of an INI file. Returns sections in declaration order.
pub fn read_all(path: &Path) -> Vec<Section> {
    let Ok(text) = fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut out: Vec<Section> = Vec::new();
    let mut cur: Option<Section> = None;
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        if let Some(stripped) = t.strip_prefix('[') {
            if let Some(name) = stripped.strip_suffix(']') {
                if let Some(s) = cur.take() {
                    out.push(s);
                }
                cur = Some(Section { id: name.trim().to_string(), keys: BTreeMap::new() });
                continue;
            }
        }
        if t.starts_with(';') || t.starts_with('#') {
            continue;
        }
        let Some(s) = cur.as_mut() else { continue };
        if let Some(eq) = t.find('=') {
            let key = t[..eq].trim().to_string();
            let mut val = t[eq + 1..].trim().to_string();
            // Strip an inline ` ; ...` or ` # ...` comment.
            val = strip_inline_comment(&val);
            s.keys.insert(key, val);
        }
    }
    if let Some(s) = cur {
        out.push(s);
    }
    out
}

fn strip_inline_comment(val: &str) -> String {
    // Replicates the PS regex `^(.*?)\s+[;#]\s.*$`: comment marker must be
    // surrounded by whitespace, so `;` inside a path like
    // `C:\foo;bar\file` is preserved.
    let mut prev_was_space = false;
    for (i, c) in val.char_indices() {
        if (c == ';' || c == '#') && prev_was_space {
            let rest = &val[i + c.len_utf8()..];
            // require at least one char of trailing context (matches PS `\s.*$`)
            if rest.chars().next().map_or(false, char::is_whitespace) {
                return val[..i].trim_end().to_string();
            }
        }
        prev_was_space = c.is_whitespace();
    }
    val.trim_end().to_string()
}

/// Read only the named section's keys, or empty if not present.
pub fn read_section(path: &Path, section: &str) -> BTreeMap<String, String> {
    for s in read_all(path) {
        if s.id.eq_ignore_ascii_case(section) {
            return s.keys;
        }
    }
    BTreeMap::new()
}

/// Replace one key inside the named section, preserving every other line
/// (comments, key order, other sections). If the section doesn't exist it is
/// appended; if the key doesn't exist within the section it is appended at
/// the end of the section.
pub fn replace_key(path: &Path, section: &str, key: &str, value: &str) -> std::io::Result<()> {
    let new_line = format!("{key} = {value}");
    let content = fs::read_to_string(path).unwrap_or_default();

    let header = format!("[{section}]");
    let Some(header_pos) = find_section_header(&content, &header) else {
        // Append a fresh section
        let mut out = content;
        if !out.is_empty() && !out.ends_with('\n') {
            out.push_str("\r\n");
        }
        if !out.is_empty() {
            out.push_str("\r\n");
        }
        out.push_str(&header);
        out.push_str("\r\n");
        out.push_str(&new_line);
        out.push_str("\r\n");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        return fs::write(path, out);
    };

    let section_start = header_pos + header.len();
    // Skip the trailing newline of the header line itself.
    let section_start = section_start
        + content[section_start..]
            .find('\n')
            .map(|n| n + 1)
            .unwrap_or(0);
    let section_end = next_section_start(&content, section_start).unwrap_or(content.len());
    let section_body = &content[section_start..section_end];

    let mut new_body = String::new();
    let mut replaced = false;
    let mut lines_iter = section_body.split_inclusive('\n').peekable();
    while let Some(line) = lines_iter.next() {
        let trimmed = line.trim_start();
        if !replaced && line_starts_with_key(trimmed, key) {
            new_body.push_str(&new_line);
            new_body.push_str(if line.ends_with("\r\n") { "\r\n" } else { "\n" });
            replaced = true;
        } else {
            new_body.push_str(line);
        }
    }
    if !replaced {
        // Append before any trailing blank lines
        let trimmed = new_body.trim_end_matches(['\r', '\n']);
        let tail = &new_body[trimmed.len()..];
        new_body = format!("{trimmed}\r\n{new_line}\r\n{tail}");
    }

    let mut out = String::with_capacity(content.len() + new_line.len());
    out.push_str(&content[..section_start]);
    out.push_str(&new_body);
    out.push_str(&content[section_end..]);

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, out)
}

/// Replace (or insert) an entire named section. Other sections are preserved
/// byte-for-byte. Used by the presets editor: hand-edits within the section
/// being rewritten are lost, hand-edits elsewhere survive.
pub fn replace_section(path: &Path, section_name: &str, section_body: &str) -> std::io::Result<()> {
    let header = format!("[{section_name}]");
    let new_section = ensure_trailing_newline(section_body.trim_end());
    let content = fs::read_to_string(path).unwrap_or_default();

    let Some(header_pos) = find_section_header(&content, &header) else {
        // Append new section
        let mut out = content;
        if !out.is_empty() {
            out = out.trim_end_matches(['\r', '\n']).to_string();
            out.push_str("\r\n\r\n");
        }
        out.push_str(&new_section);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        return fs::write(path, out);
    };

    let next = next_section_start(&content, header_pos + header.len()).unwrap_or(content.len());
    let before = &content[..header_pos];
    let after = &content[next..];
    let separator = if after.is_empty() { "" } else { "\r\n" };

    let mut out = String::with_capacity(before.len() + new_section.len() + after.len() + 4);
    out.push_str(before);
    out.push_str(&new_section);
    out.push_str(separator);
    out.push_str(after);

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, out)
}

/// Remove a section entirely. No-op if missing.
pub fn delete_section(path: &Path, section_name: &str) -> std::io::Result<()> {
    let header = format!("[{section_name}]");
    let content = match fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return Ok(()),
    };
    let Some(header_pos) = find_section_header(&content, &header) else {
        return Ok(());
    };
    let next = next_section_start(&content, header_pos + header.len()).unwrap_or(content.len());
    let mut out = String::with_capacity(content.len());
    out.push_str(&content[..header_pos]);
    out.push_str(&content[next..]);
    // Tidy: collapse multiple blank separators left behind.
    let tidied = out
        .replace("\r\n\r\n\r\n", "\r\n\r\n")
        .replace("\n\n\n", "\n\n");
    fs::write(path, tidied)
}

fn line_starts_with_key(line: &str, key: &str) -> bool {
    let line = line.trim_start();
    if !line.to_ascii_lowercase().starts_with(&key.to_ascii_lowercase()) {
        return false;
    }
    let rest = &line[key.len()..];
    let r = rest.trim_start();
    r.starts_with('=')
}

fn find_section_header(content: &str, header: &str) -> Option<usize> {
    // Match `[Name]` at the start of a line (after \n or at offset 0).
    let mut start = 0;
    loop {
        let idx = content[start..].find(header)?;
        let abs = start + idx;
        let prev = abs.checked_sub(1).and_then(|i| content.as_bytes().get(i));
        let line_start = matches!(prev, None | Some(b'\n'));
        // The header must be the entire bracketed group at line start: check
        // the next char is the matching `]` already consumed inside `header`
        // and the char after is end-of-line.
        let after = content.as_bytes().get(abs + header.len());
        let line_end = matches!(after, None | Some(b'\r') | Some(b'\n'));
        if line_start && line_end {
            return Some(abs);
        }
        start = abs + 1;
    }
}

fn next_section_start(content: &str, from: usize) -> Option<usize> {
    let bytes = content.as_bytes();
    let mut i = from;
    while i < bytes.len() {
        if bytes[i] == b'\n' {
            let line_start = i + 1;
            if bytes.get(line_start) == Some(&b'[') {
                return Some(line_start);
            }
        }
        i += 1;
    }
    None
}

fn ensure_trailing_newline(s: &str) -> String {
    if s.is_empty() {
        return String::new();
    }
    if s.ends_with('\n') {
        s.to_string()
    } else {
        let mut out = s.to_string();
        out.push_str("\r\n");
        out
    }
}

/// Parse a value as i32 if non-empty and parseable.
pub fn parse_int(s: &str) -> Option<i32> {
    s.trim().parse().ok()
}

/// Parse a value as f64 if non-empty and parseable.
pub fn parse_float(s: &str) -> Option<f64> {
    s.trim().parse().ok()
}

/// Parse `true` / `false` (lowercase only — matches the PowerShell helper).
pub fn parse_bool(s: &str) -> Option<bool> {
    match s.trim() {
        "true" => Some(true),
        "false" => Some(false),
        _ => None,
    }
}
