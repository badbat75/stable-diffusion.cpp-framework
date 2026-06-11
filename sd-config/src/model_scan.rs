// Catalogue weights files under the user's ModelsDir so the GUI can offer
// dropdowns per category instead of a generic file picker.
//
// Layout convention (the reference tree under `E:\stable-diffusion.cpp\`):
//
//   E:\stable-diffusion.cpp\
//       models\           ← ModelsDir points here (the main-models bucket)
//       vaes\             ← sibling, holds VAEs
//       loras\            ← sibling, holds LoRAs (scanned RECURSIVELY — see
//                           Category::Lora — so per-model sub-folders work)
//       text_encoders\
//           llm\          ← LLM
//           t5xxls\       ← T5-XXL
//           clips\        ← CLIP-L & CLIP-G (both dropdowns list the lot;
//                           user picks which file is L vs G)
//
// ModelsDir is the *bucket* (where `.gguf` / `.safetensors` files live —
// what `infer_models_dir` writes on preset save: the parent of the picked
// model). Sub-models are looked up via `..\<bucket>` siblings of ModelsDir.
//
// Filtering rule: anything in the resolved directory with a `.safetensors`
// or `.gguf` extension is listed verbatim — no basename heuristics. If a
// dropdown ends up cluttered the user can rename or relocate files; the
// configurator doesn't second-guess what belongs where.
//
// LoRAs differ from the flat sub-models in two ways: their bucket is walked
// RECURSIVELY (users file LoRAs into per-model sub-folders) and each hit is
// labelled by its path RELATIVE to the loras root. The GUI shows/edits those
// relative paths, but presets.ini keeps FULL paths — the round-trip lives in
// `lora_full_to_display` / `lora_display_to_full` at the bottom of this file.
//
// To stay forgiving when users have an alternate layout (everything nested
// under one root), each category also probes a few `<ModelsDir>\<bucket>`
// fallbacks. Missing folders are silently skipped; if every probe is empty
// the dropdown just shows `(none)` / `(custom)`.

use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone)]
pub struct FileOption {
    /// What the user sees inside the ComboBox. Basename for the flat
    /// categories; for `Lora` it's the path RELATIVE to the loras root
    /// (e.g. `realism\foo.safetensors`) so files in subfolders stay
    /// distinguishable.
    pub label: String,
    /// Absolute path — what gets written into presets.ini.
    pub path: String,
}

#[derive(Copy, Clone, Debug)]
pub enum Category {
    Model,
    Vae,
    Llm,
    T5xxl,
    ClipL,
    ClipG,
    Lora,
}

impl Category {
    /// VAE / LLM / T5-XXL / CLIP-L / CLIP-G / LoRA are all optional sub-models —
    /// the user must be able to clear them ((none) sentinel). The main
    /// diffusion model is required.
    pub fn is_optional(self) -> bool {
        !matches!(self, Category::Model)
    }

    /// LoRAs are organised into per-model subfolders, so their bucket is
    /// walked recursively (relative-path labels). Every other category is a
    /// single flat directory of basenames.
    fn is_recursive(self) -> bool {
        matches!(self, Category::Lora)
    }

    /// Directories to probe, expressed relative to `ModelsDir`. An empty
    /// string means ModelsDir itself; entries starting with `..` reach the
    /// bucket root for users following the canonical sibling layout.
    /// Listed in priority order — duplicates that resolve to the same
    /// directory after normalisation are deduped by `list`.
    fn scan_relatives(self) -> &'static [&'static str] {
        match self {
            // ModelsDir IS the main-models bucket; the others are fallbacks
            // for users whose ModelsDir points one level higher (root).
            Category::Model => &["", "models", "diffusion_models"],

            Category::Vae => &["../vaes", "../vae", "vaes", "vae"],

            Category::Llm => &["../text_encoders/llm", "../llm", "text_encoders/llm", "llm"],

            Category::T5xxl => &[
                "../text_encoders/t5xxls",
                "../text_encoders/t5xxl",
                "../t5xxls",
                "../t5xxl",
                "text_encoders/t5xxls",
                "text_encoders/t5xxl",
                "t5xxls",
                "t5xxl",
            ],

            Category::ClipL | Category::ClipG => &[
                "../text_encoders/clips",
                "../clips",
                "text_encoders/clips",
                "clips",
            ],

            // Sibling `loras\` bucket (next to `models\`, like `vaes\`), with
            // the same nested-under-root fallbacks as the other categories.
            Category::Lora => &["../loras", "../lora", "loras", "lora"],
        }
    }
}

pub fn list(models_dir: &str, category: Category) -> Vec<FileOption> {
    if models_dir.trim().is_empty() {
        return Vec::new();
    }
    let root = PathBuf::from(models_dir);
    let mut out: Vec<FileOption> = Vec::new();
    let mut seen_paths: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut seen_dirs: std::collections::HashSet<String> = std::collections::HashSet::new();

    for rel in category.scan_relatives() {
        let raw_dir = if rel.is_empty() {
            root.clone()
        } else {
            root.join(rel)
        };
        // Collapse `..` segments so e.g. `E:\sd\models\..\vaes` becomes
        // `E:\sd\vaes` — both for the existence check and for the paths we
        // hand back to the GUI / write into presets.ini.
        let dir = normalize(&raw_dir);
        let dir_key = dir.to_string_lossy().to_ascii_lowercase();
        if !seen_dirs.insert(dir_key) {
            // Same directory reached via two different relatives — skip.
            continue;
        }
        if !dir.is_dir() {
            continue;
        }
        if category.is_recursive() {
            collect_recursive(&dir, &mut out, &mut seen_paths);
        } else {
            collect_flat(&dir, &mut out, &mut seen_paths);
        }
    }

    out.sort_by_key(|a| a.label.to_ascii_lowercase());
    out
}

/// Single-level scan: every weights file directly in `dir`, labelled by basename.
fn collect_flat(
    dir: &Path,
    out: &mut Vec<FileOption>,
    seen_paths: &mut std::collections::HashSet<String>,
) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if !p.is_file() || !is_weights_ext(&p) {
            continue;
        }
        let Some(name) = p
            .file_name()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
        else {
            continue;
        };
        let path_str = normalize(&p).to_string_lossy().into_owned();
        if seen_paths.insert(path_str.to_ascii_lowercase()) {
            out.push(FileOption {
                label: name,
                path: path_str,
            });
        }
    }
}

/// Recursive scan rooted at `base`: every weights file anywhere beneath it,
/// labelled by its path relative to `base` (back-slash separated). Used for
/// LoRAs, which users tend to file into per-model subfolders.
fn collect_recursive(
    base: &Path,
    out: &mut Vec<FileOption>,
    seen_paths: &mut std::collections::HashSet<String>,
) {
    // Manual stack walk — no walkdir dependency. `base` carries no `..`/`.`
    // (it's already normalized by `list`), and read_dir yields child paths as
    // `dir.join(name)`, so every descendant keeps `base` as a clean prefix and
    // `strip_prefix(base)` gives the relative label.
    let mut stack = vec![base.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&d) else {
            continue;
        };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
                continue;
            }
            if !p.is_file() || !is_weights_ext(&p) {
                continue;
            }
            let path_str = normalize(&p).to_string_lossy().into_owned();
            if !seen_paths.insert(path_str.to_ascii_lowercase()) {
                continue;
            }
            let label = p
                .strip_prefix(base)
                .ok()
                .map(|r| r.to_string_lossy().into_owned())
                .filter(|s| !s.is_empty())
                .or_else(|| p.file_name().map(|s| s.to_string_lossy().into_owned()))
                .unwrap_or_else(|| path_str.clone());
            out.push(FileOption {
                label,
                path: path_str,
            });
        }
    }
}

/// Drop `.` and resolve `..` components lexically — no filesystem touch, so
/// it works even when the resulting path doesn't exist yet. Adequate for
/// the sibling-traversals we do here (`<ModelsDir>\..\vaes`).
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn is_weights_ext(p: &Path) -> bool {
    matches!(
        p.extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_ascii_lowercase())
            .as_deref(),
        Some("safetensors") | Some("gguf")
    )
}

/// Render the on-disk catalogue + the currently-saved value into a triple of
/// `(labels, values, current_index)` suitable for driving a ComboBox.
///
/// Behaviour:
///   * Optional categories prepend a `(none)` sentinel mapping to the empty
///     string so the user can clear the field via the dropdown.
///   * If `current` is non-empty and matches one of the scanned paths
///     (case-insensitive — Windows), that index is returned as `current_index`.
///   * Otherwise `current` is injected as a `(custom) <basename>` row at the
///     top of the substantive list so the saved value remains visible and
///     editable without forcing the user to relocate the file.
pub fn build_options(
    category: Category,
    scanned: Vec<FileOption>,
    current: &str,
) -> (Vec<String>, Vec<String>, i32) {
    let mut labels: Vec<String> = Vec::new();
    let mut values: Vec<String> = Vec::new();

    if category.is_optional() {
        labels.push("(none)".into());
        values.push(String::new());
    }
    for opt in scanned {
        labels.push(opt.label);
        values.push(opt.path);
    }

    let current_trim = current.trim();
    if current_trim.is_empty() {
        // Empty saved value → if optional, point at the (none) row; otherwise
        // leave the ComboBox unselected (-1) until the user picks something.
        return (labels, values, if category.is_optional() { 0 } else { -1 });
    }

    if let Some(i) = values.iter().position(|v| paths_eq(v, current_trim)) {
        return (labels, values, i as i32);
    }

    let basename = Path::new(current_trim)
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| current_trim.to_string());
    let insert_at = if category.is_optional() { 1 } else { 0 };
    labels.insert(insert_at, format!("(custom) {basename}"));
    values.insert(insert_at, current_trim.to_string());
    (labels, values, insert_at as i32)
}

fn paths_eq(a: &str, b: &str) -> bool {
    // Windows paths are case-insensitive. Existing presets may use forward
    // slashes (some PS scripts wrote those); normalise both sides so a
    // forward-slash value still matches the back-slash scan output.
    fn norm(s: &str) -> String {
        s.trim().replace('/', "\\").to_ascii_lowercase()
    }
    norm(a) == norm(b)
}

// ── LoRA storage ↔ display conversion ────────────────────────────────────
//
// presets.ini stores `lora` as comma-separated FULL paths, each optionally
// `:<multiplier>` — the runtime scripts (run-server.ps1 / mcp-server.ps1)
// depend on that and are deliberately left untouched. The GUI splits each
// entry into TWO positionally-aligned fields: a RELATIVE path (under the
// discovered loras root, so the user never edits a wall of absolute paths)
// and its weight. `lora_split_display` is the load boundary (FULL `lora`
// string → relative-paths-csv + weights-csv); `lora_combine_full` is the save
// boundary (the two fields back into the FULL `lora` string). Round-trips an
// untouched preset byte-for-byte; an empty value passes straight through.
//
// Both directions need the recursive loras scan + root list. That walk is the
// expensive part, so callers build it ONCE per UI event via `LoraScan::new`
// and pass the same `&LoraScan` to both the split and the combine (and reuse
// its `scanned` for the "+ Add a LoRA…" dropdown) — see gui.rs.

/// One recursive scan of the loras tree, shared across the split/combine pair
/// and the add-dropdown within a single UI event. ModelsDir can change between
/// events, so this is rebuilt per event — deliberately NOT a long-lived cache.
pub struct LoraScan {
    pub scanned: Vec<FileOption>,
    roots: Vec<PathBuf>,
}

impl LoraScan {
    pub fn new(models_dir: &str) -> Self {
        LoraScan {
            scanned: list(models_dir, Category::Lora),
            roots: lora_roots(models_dir),
        }
    }
}

/// Split a stored FULL `lora` value into (relative-paths-csv, weights-csv),
/// aligned by position. `weights` is "" when no entry carried a multiplier
/// (the common case); otherwise each slot holds that entry's multiplier or ""
/// (= default 1.0). Inverse of `lora_combine_full`.
pub fn lora_split_display(scan: &LoraScan, value: &str) -> (String, String) {
    if value.trim().is_empty() {
        return (String::new(), String::new());
    }
    let scanned = &scan.scanned;
    let roots = &scan.roots;
    let mut paths: Vec<String> = Vec::new();
    let mut weights: Vec<String> = Vec::new();
    for raw in value.split(',') {
        let spec = raw.trim();
        if spec.is_empty() {
            continue;
        }
        let (path, suffix) = split_lora_multiplier(spec);
        if path.is_empty() {
            continue;
        }
        paths.push(relativize_lora(scanned, roots, path));
        // suffix is ":<num>" or ""; the field wants the bare number.
        weights.push(suffix.strip_prefix(':').unwrap_or("").trim().to_string());
    }
    let paths_csv = paths.join(", ");
    // Collapse an all-default weights list to a single empty field so a preset
    // with no multipliers shows a blank Weight box rather than ", , ".
    let weights_csv = if weights.iter().all(|w| w.is_empty()) {
        String::new()
    } else {
        weights.join(", ")
    };
    (paths_csv, weights_csv)
}

/// Combine a relative-paths-csv and a positional weights-csv back into a stored
/// FULL `lora` value (`fullpath:mult, …`). A blank or non-numeric weight slot
/// is omitted (defaults to 1.0) — a non-numeric suffix would otherwise make
/// ConvertTo-LoraEntries swallow it into the path. Inverse of
/// `lora_split_display`.
pub fn lora_combine_full(scan: &LoraScan, paths_csv: &str, weights_csv: &str) -> String {
    if paths_csv.trim().is_empty() {
        return String::new();
    }
    let scanned = &scan.scanned;
    let roots = &scan.roots;
    let weights: Vec<&str> = weights_csv.split(',').map(|w| w.trim()).collect();
    let mut out: Vec<String> = Vec::new();
    let mut idx = 0usize; // indexes NON-empty paths, matching how split aligns
    for raw in paths_csv.split(',') {
        let rel = raw.trim();
        if rel.is_empty() {
            continue;
        }
        let full = absolutize_lora(scanned, roots, rel);
        let w = weights.get(idx).copied().unwrap_or("");
        if !w.is_empty() && w.parse::<f64>().is_ok() {
            out.push(format!("{full}:{w}"));
        } else {
            out.push(full);
        }
        idx += 1;
    }
    out.join(", ")
}

/// One LoRA path, stored FULL → RELATIVE display (path only; the caller peels
/// the multiplier off first).
fn relativize_lora(scanned: &[FileOption], roots: &[PathBuf], path: &str) -> String {
    // Prefer the scanned label (correct on-disk case) when the file exists.
    if let Some(o) = scanned.iter().find(|o| paths_eq(&o.path, path)) {
        return o.label.clone();
    }
    // Not in the scan but still under a loras root → strip the root.
    if let Some(rel) = strip_lora_root(roots, path) {
        return rel;
    }
    // Genuinely outside the loras folder → leave the full path visible.
    path.to_string()
}

/// One LoRA path, RELATIVE display → stored FULL (path only).
fn absolutize_lora(scanned: &[FileOption], roots: &[PathBuf], rel: &str) -> String {
    // Already absolute (drive letter / UNC) → trust it verbatim.
    if is_absolute_path(rel) {
        return rel.to_string();
    }
    // Matches a scanned relative label → its absolute path (exact).
    if let Some(o) = scanned.iter().find(|o| paths_eq(&o.label, rel)) {
        return o.path.clone();
    }
    // Hand-typed / moved file: best-effort join onto the primary root so the
    // runtime still receives an absolute path.
    if let Some(root) = roots.first() {
        return normalize(&root.join(rel)).to_string_lossy().into_owned();
    }
    rel.to_string()
}

/// The existing loras-root directories under `models_dir`, in priority order
/// (the same probes the scanner uses). Used to strip the root off a full path
/// for display and to rejoin a hand-typed relative path.
fn lora_roots(models_dir: &str) -> Vec<PathBuf> {
    if models_dir.trim().is_empty() {
        return Vec::new();
    }
    let root = PathBuf::from(models_dir);
    let mut out = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for rel in Category::Lora.scan_relatives() {
        let dir = normalize(&root.join(rel));
        if !seen.insert(dir.to_string_lossy().to_ascii_lowercase()) {
            continue;
        }
        if dir.is_dir() {
            out.push(dir);
        }
    }
    out
}

/// Split one `lora` spec into (path, multiplier-suffix). The suffix is the
/// trailing `:<number>` (colon included) or "" when absent — only a numeric
/// tail counts, so the drive colon in `E:\…` is never split off (mirrors
/// ConvertTo-LoraEntries in common-functions.ps1).
pub fn split_lora_multiplier(spec: &str) -> (&str, &str) {
    let s = spec.trim();
    if let Some(i) = s.rfind(':') {
        if i > 1 && s[i + 1..].trim().parse::<f64>().is_ok() {
            return (s[..i].trim_end(), &s[i..]);
        }
    }
    (s, "")
}

/// `E:\…`, `\\server\share`, `/abs` → absolute; `realism\foo` → relative.
/// Hand-rolled (not `Path::is_absolute`) so the classification is identical
/// regardless of the host OS the crate is compiled on.
fn is_absolute_path(s: &str) -> bool {
    let b = s.as_bytes();
    (b.len() >= 2 && b[1] == b':') || s.starts_with('\\') || s.starts_with('/')
}

/// Strip a loras-root prefix off `path`, returning the remainder in its
/// original case. Case-insensitive (Windows) and only matches at a directory
/// boundary, so `…\loras_extra\x` is NOT treated as living under `…\loras`.
/// None when `path` is under no root (or equals a root exactly).
fn strip_lora_root(roots: &[PathBuf], path: &str) -> Option<String> {
    // `to_ascii_lowercase` preserves byte length (non-ASCII bytes pass through
    // untouched), so a byte offset computed on the lowercased copy is a valid
    // boundary in the original — the tail recovers the on-disk case.
    let p = path.replace('/', "\\");
    let p_l = p.to_ascii_lowercase();
    for root in roots {
        let r_l = root
            .to_string_lossy()
            .replace('/', "\\")
            .to_ascii_lowercase();
        let r_l = r_l.trim_end_matches('\\');
        if let Some(rest) = p_l.strip_prefix(r_l) {
            if rest.starts_with('\\') {
                let tail = p[p.len() - rest.len()..].trim_start_matches('\\');
                if !tail.is_empty() {
                    return Some(tail.to_string());
                }
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multiplier_split_respects_drive_colon() {
        assert_eq!(
            split_lora_multiplier("foo.safetensors"),
            ("foo.safetensors", "")
        );
        assert_eq!(
            split_lora_multiplier("foo.safetensors:0.6"),
            ("foo.safetensors", ":0.6")
        );
        // The drive colon is NOT a multiplier.
        assert_eq!(
            split_lora_multiplier("E:\\loras\\foo.safetensors"),
            ("E:\\loras\\foo.safetensors", ""),
        );
        assert_eq!(
            split_lora_multiplier("E:\\loras\\foo.safetensors:0.6"),
            ("E:\\loras\\foo.safetensors", ":0.6"),
        );
        // A non-numeric tail stays part of the path.
        assert_eq!(split_lora_multiplier("a:b"), ("a:b", ""));
    }

    #[test]
    fn absolute_path_classification() {
        assert!(is_absolute_path("E:\\loras\\foo.safetensors"));
        assert!(is_absolute_path("\\\\server\\share\\foo.safetensors"));
        assert!(is_absolute_path("/abs/foo"));
        assert!(!is_absolute_path("realism\\foo.safetensors"));
        assert!(!is_absolute_path("foo.safetensors"));
    }

    #[test]
    fn strip_root_only_at_directory_boundary() {
        let roots = vec![PathBuf::from("E:\\stable-diffusion.cpp\\loras")];
        assert_eq!(
            strip_lora_root(
                &roots,
                "E:\\stable-diffusion.cpp\\loras\\realism\\foo.safetensors"
            )
            .as_deref(),
            Some("realism\\foo.safetensors"),
        );
        // Case-insensitive root match; remainder keeps its on-disk case.
        assert_eq!(
            strip_lora_root(&roots, "e:\\stable-diffusion.cpp\\LORAS\\Foo.safetensors").as_deref(),
            Some("Foo.safetensors"),
        );
        // `loras_extra` shares a string prefix but is a DIFFERENT directory.
        assert_eq!(
            strip_lora_root(
                &roots,
                "E:\\stable-diffusion.cpp\\loras_extra\\foo.safetensors"
            ),
            None,
        );
        // Outside the root entirely.
        assert_eq!(strip_lora_root(&roots, "E:\\models\\foo.safetensors"), None);
    }

    #[test]
    fn combine_attaches_only_numeric_weights_positionally() {
        // Empty models_dir → no scan/roots, so relative paths pass through
        // as-is (absolutize falls through to the verbatim string). Lets us test
        // the weight zipping in isolation.
        let scan = LoraScan::new("");
        assert_eq!(
            lora_combine_full(&scan, "a.safetensors, b.safetensors", "0.6, 0.8"),
            "a.safetensors:0.6, b.safetensors:0.8",
        );
        // Blank and non-numeric weight slots are dropped (default 1.0); a
        // missing trailing slot defaults too.
        assert_eq!(lora_combine_full(&scan, "a, b, c", "0.6, , x"), "a:0.6, b, c",);
        assert_eq!(lora_combine_full(&scan, "", "0.6"), "");
    }
}
