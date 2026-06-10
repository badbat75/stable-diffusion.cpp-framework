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

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Default, Clone)]
pub struct Section {
    pub id: String,
    pub keys: BTreeMap<String, String>,
}

/// Read a file that may legitimately not exist yet: `NotFound` becomes an
/// empty string, every other error (invalid UTF-8 from an ANSI hand-edit,
/// sharing violation, permissions) propagates. Treating those as "empty"
/// would make the write paths below silently rebuild the file from a single
/// section, destroying every other preset — see replace_section's contract.
/// A leading UTF-8 BOM (PS 5.1 `Out-File`, some editors) is stripped so the
/// first `[Section]` header is recognized; writes never re-add it.
fn read_existing(path: &Path) -> std::io::Result<String> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(text.strip_prefix('\u{feff}').map(str::to_string).unwrap_or(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(e),
    }
}

/// Parse all sections of an INI file. Returns sections in declaration order.
/// A missing file reads as empty; any other IO error propagates.
pub fn read_all(path: &Path) -> std::io::Result<Vec<Section>> {
    let text = read_existing(path)?;
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
            let val = t[eq + 1..].trim();
            // Strip an inline ` ; ...` or ` # ...` comment.
            s.keys.insert(key, strip_inline_comment(val).into_owned());
        }
    }
    if let Some(s) = cur {
        out.push(s);
    }
    Ok(out)
}

fn strip_inline_comment(val: &str) -> Cow<'_, str> {
    // Replicates the PS regex `^(.*?)\s+[;#]\s.*$`: comment marker must be
    // surrounded by whitespace, so `;` inside a path like
    // `C:\foo;bar\file` is preserved.
    //
    // The common case is "no inline comment present" — return the borrowed
    // input unchanged so the caller can avoid an allocation entirely.
    let mut prev_was_space = false;
    for (i, c) in val.char_indices() {
        if (c == ';' || c == '#') && prev_was_space {
            let rest = &val[i + c.len_utf8()..];
            // require at least one char of trailing context (matches PS `\s.*$`)
            if rest.chars().next().map_or(false, char::is_whitespace) {
                return Cow::Owned(val[..i].trim_end().to_string());
            }
        }
        prev_was_space = c.is_whitespace();
    }
    // No inline comment → caller already trimmed; borrow the input as-is.
    let trimmed = val.trim_end();
    if trimmed.len() == val.len() {
        Cow::Borrowed(val)
    } else {
        Cow::Borrowed(trimmed)
    }
}

/// Read only the named section's keys, or empty if not present.
pub fn read_section(path: &Path, section: &str) -> std::io::Result<BTreeMap<String, String>> {
    for s in read_all(path)? {
        if s.id.eq_ignore_ascii_case(section) {
            return Ok(s.keys);
        }
    }
    Ok(BTreeMap::new())
}

/// Replace one key inside the named section, preserving every other line
/// (comments, key order, other sections). If the section doesn't exist it is
/// appended; if the key doesn't exist within the section it is appended at
/// the end of the section.
pub fn replace_key(path: &Path, section: &str, key: &str, value: &str) -> std::io::Result<()> {
    let new_line = format!("{key} = {value}");
    let content = read_existing(path)?;

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
    let content = read_existing(path)?;

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

/// Rename a section in place by rewriting its `[old]` header line as `[new]`.
/// Every key/comment/blank line within the section is preserved and the
/// section keeps its position in the file (unlike a delete + re-save, which
/// would move it to the end).
///
/// Errors with `NotFound` if `old` is missing, `AlreadyExists` if `new` is
/// already present. Caller is responsible for guarding against `old == new`
/// (which would also trigger AlreadyExists otherwise).
pub fn rename_section(path: &Path, old: &str, new: &str) -> std::io::Result<()> {
    let old_header = format!("[{old}]");
    let new_header = format!("[{new}]");
    let content = read_existing(path)?;
    let Some(pos) = find_section_header(&content, &old_header) else {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("section [{old}] not found"),
        ));
    };
    if find_section_header(&content, &new_header).is_some() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!("section [{new}] already exists"),
        ));
    }
    let mut out = String::with_capacity(content.len() + new.len());
    out.push_str(&content[..pos]);
    out.push_str(&new_header);
    out.push_str(&content[pos + old_header.len()..]);
    fs::write(path, out)
}

/// Remove a section entirely. No-op if missing.
pub fn delete_section(path: &Path, section_name: &str) -> std::io::Result<()> {
    let header = format!("[{section_name}]");
    let content = read_existing(path)?;
    let Some(header_pos) = find_section_header(&content, &header) else {
        return Ok(());
    };
    let next = next_section_start(&content, header_pos + header.len()).unwrap_or(content.len());
    let mut out = String::with_capacity(content.len());
    out.push_str(&content[..header_pos]);
    out.push_str(&content[next..]);
    // Interior deletions need no tidying — the bytes on either side of the
    // splice belong to the *surrounding* sections and must stay untouched
    // (a whole-file blank-line collapse here would edit sections the delete
    // never touched). Only deleting the LAST section leaves the previous
    // separator's blank lines dangling at EOF — trim those to one newline.
    if next >= content.len() {
        let trimmed = out.trim_end_matches(['\r', '\n']).len();
        if trimmed > 0 && trimmed < out.len() {
            let ending = if out[trimmed..].contains('\r') { "\r\n" } else { "\n" };
            out.truncate(trimmed);
            out.push_str(ending);
        } else if trimmed == 0 {
            out.clear();
        }
    }
    fs::write(path, out)
}

fn line_starts_with_key(line: &str, key: &str) -> bool {
    let line = line.trim_start();
    // Keys in server.ini / presets.ini are pure-ASCII (PascalCase),
    // so a byte-length slice is sound — but guard the char boundary
    // defensively in case a future schema introduces non-ASCII keys.
    if line.len() < key.len() || !line.is_char_boundary(key.len()) {
        return false;
    }
    if !line[..key.len()].eq_ignore_ascii_case(key) {
        return false;
    }
    let rest = &line[key.len()..];
    let r = rest.trim_start();
    r.starts_with('=')
}

fn find_section_header(content: &str, header: &str) -> Option<usize> {
    // Match `[Name]` as an entire line, ASCII-case-insensitively: the read
    // side (read_section) accepts a hand-written `[server]` for "Server", so
    // the write side must find it too — an exact match would append a
    // duplicate canonical-case section instead of updating in place.
    let mut offset = 0;
    for line in content.split_inclusive('\n') {
        let body = line.trim_end_matches(['\r', '\n']);
        if body.eq_ignore_ascii_case(header) {
            return Some(offset);
        }
        offset += line.len();
    }
    None
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

/// Parse `true` / `false` case-insensitively — the PowerShell reader's
/// `-eq 'true'` is case-insensitive, so `mmap = True` must round-trip here
/// too instead of silently reverting to the form default on the next save.
pub fn parse_bool(s: &str) -> Option<bool> {
    let t = s.trim();
    if t.eq_ignore_ascii_case("true") {
        Some(true)
    } else if t.eq_ignore_ascii_case("false") {
        Some(false)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    /// Per-test scratch file under the OS temp dir; removed on drop so
    /// parallel test runs never collide (names embed the test's own tag).
    struct TempIni(PathBuf);
    impl TempIni {
        fn new(tag: &str, contents: &[u8]) -> Self {
            let path = std::env::temp_dir().join(format!(
                "sd-config-ini-test-{tag}-{}.ini",
                std::process::id()
            ));
            fs::write(&path, contents).unwrap();
            TempIni(path)
        }
    }
    impl Drop for TempIni {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    #[test]
    fn inline_comment_strip() {
        assert_eq!(strip_inline_comment("30 ; high quality"), "30");
        assert_eq!(strip_inline_comment("30 # note"), "30");
        // `;` without surrounding whitespace is part of the value (paths).
        assert_eq!(strip_inline_comment(r"C:\foo;bar\file"), r"C:\foo;bar\file");
        assert_eq!(strip_inline_comment("plain"), "plain");
    }

    #[test]
    fn bom_file_reads_and_roundtrips_without_bom() {
        let t = TempIni::new("bom", "\u{feff}[Server]\r\nPort = 8180\r\n".as_bytes());
        let sections = read_all(&t.0).unwrap();
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].id, "Server");
        assert_eq!(sections[0].keys["Port"], "8180");

        // Updating in place must hit the existing section, not append a
        // duplicate, and the rewritten file must not carry the BOM forward.
        replace_key(&t.0, "Server", "Port", "9999").unwrap();
        let out = fs::read(&t.0).unwrap();
        assert!(!out.starts_with("\u{feff}".as_bytes()));
        let text = String::from_utf8(out).unwrap();
        assert_eq!(text.matches("[Server]").count(), 1);
        assert!(text.contains("Port = 9999"));
    }

    #[test]
    fn replace_section_is_case_insensitive() {
        let t = TempIni::new("case", b"[server]\r\nPort = 1\r\n");
        replace_section(&t.0, "Server", "[Server]\r\nPort = 2\r\n").unwrap();
        let text = fs::read_to_string(&t.0).unwrap();
        assert!(!text.contains("[server]"), "old lowercase header must be replaced:\n{text}");
        assert_eq!(text.to_lowercase().matches("[server]").count(), 1);
        assert!(text.contains("Port = 2"));
    }

    #[test]
    fn delete_preserves_other_sections_byte_for_byte() {
        // [a] deliberately carries a hand-kept double blank line that a
        // whole-file tidy pass would have collapsed.
        let a = "[a]\r\nx = 1\r\n; kept comment\r\n\r\n\r\n; second comment after 2 blanks\r\n";
        let b = "[b]\r\ny = 2\r\n";
        let c = "[c]\r\nz = 3\r\n";
        let t = TempIni::new("delete", format!("{a}{b}{c}").as_bytes());
        delete_section(&t.0, "b").unwrap();
        let text = fs::read_to_string(&t.0).unwrap();
        assert_eq!(text, format!("{a}{c}"));
    }

    #[test]
    fn delete_last_section_trims_dangling_blanks() {
        let t = TempIni::new("delete-last", b"[a]\r\nx = 1\r\n\r\n[b]\r\ny = 2\r\n");
        delete_section(&t.0, "b").unwrap();
        let text = fs::read_to_string(&t.0).unwrap();
        assert_eq!(text, "[a]\r\nx = 1\r\n");
    }

    #[test]
    fn rename_preserves_body() {
        let body = "k = v\r\n; comment stays\r\n";
        let t = TempIni::new("rename", format!("[old]\r\n{body}[other]\r\nq = 1\r\n").as_bytes());
        rename_section(&t.0, "old", "new").unwrap();
        let text = fs::read_to_string(&t.0).unwrap();
        assert_eq!(text, format!("[new]\r\n{body}[other]\r\nq = 1\r\n"));
        // Renaming onto an existing id must refuse.
        let err = rename_section(&t.0, "new", "other").unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::AlreadyExists);
    }

    #[test]
    fn missing_file_reads_empty_but_invalid_utf8_errors() {
        let missing = std::env::temp_dir().join(format!(
            "sd-config-ini-test-missing-{}.ini",
            std::process::id()
        ));
        let _ = fs::remove_file(&missing);
        assert!(read_all(&missing).unwrap().is_empty());

        // Invalid UTF-8 (e.g. an ANSI hand-edit with accented chars) must
        // surface as an error — NOT as "empty file", which would let a
        // subsequent save truncate every other preset.
        let t = TempIni::new("badutf8", b"[Server]\r\nModelsDir = C:\\caff\xe8\r\n");
        assert!(read_all(&t.0).is_err());
        let before = fs::read(&t.0).unwrap();
        assert!(replace_section(&t.0, "x", "[x]\r\nk = v\r\n").is_err());
        // The unreadable file must be left untouched.
        assert_eq!(fs::read(&t.0).unwrap(), before);
    }
}
