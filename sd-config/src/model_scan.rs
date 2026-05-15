// Catalogue weights files under the user's ModelsDir so the GUI can offer
// dropdowns per category instead of a generic file picker.
//
// Layout convention (the reference tree under `E:\stable-diffusion.cpp\`):
//
//   E:\stable-diffusion.cpp\
//       models\           ← ModelsDir points here (the main-models bucket)
//       vaes\             ← sibling, holds VAEs
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
// To stay forgiving when users have an alternate layout (everything nested
// under one root), each category also probes a few `<ModelsDir>\<bucket>`
// fallbacks. Missing folders are silently skipped; if every probe is empty
// the dropdown just shows `(none)` / `(custom)`.

use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone)]
pub struct FileOption {
    /// Basename — what the user sees inside the ComboBox.
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
}

impl Category {
    /// VAE / LLM / T5-XXL / CLIP-L / CLIP-G are all optional sub-models —
    /// the user must be able to clear them ((none) sentinel). The main
    /// diffusion model is required.
    pub fn is_optional(self) -> bool {
        !matches!(self, Category::Model)
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

            Category::Llm => &[
                "../text_encoders/llm",
                "../llm",
                "text_encoders/llm",
                "llm",
            ],

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
        let raw_dir = if rel.is_empty() { root.clone() } else { root.join(rel) };
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
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for e in entries.flatten() {
            let p = e.path();
            if !p.is_file() {
                continue;
            }
            if !is_weights_ext(&p) {
                continue;
            }
            let name = match p.file_name().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            let path_str = normalize(&p).to_string_lossy().into_owned();
            let key = path_str.to_ascii_lowercase();
            if seen_paths.insert(key) {
                out.push(FileOption {
                    label: name,
                    path: path_str,
                });
            }
        }
    }

    out.sort_by(|a, b| a.label.to_ascii_lowercase().cmp(&b.label.to_ascii_lowercase()));
    out
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
