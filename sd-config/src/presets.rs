// presets.ini schema and IO.
//
// One INI section per preset; the section name is the id shown in the
// run-server.ps1 picker and in the GUI's left-hand list. Each section maps
// to sd-server CLI flags (see resources/run-server.ps1 for the mapping).
//
// Critical contract (matches the PS scripts): rewriting a section overwrites
// it in full from the form values, but hand-edits to OTHER sections in the
// file are preserved byte-for-byte. This is implemented in ini::replace_section.

use std::fs;
use std::io;
use std::path::PathBuf;

use crate::ini;
use crate::paths;
use crate::server_cfg;

#[derive(Debug, Clone, Default)]
pub struct Preset {
    pub id: String,
    pub model_type: String, // "allinone" | "standalone"
    pub model: String,
    pub vae: String,
    pub llm: String,
    pub t5xxl: String,
    pub clip_l: String,
    pub clip_g: String,
    pub lora_dir: String,
    pub embd_dir: String,
    pub weight_type: String,
    pub offload_to_cpu: Option<bool>,
    pub mmap: Option<bool>,
    pub fa: Option<bool>,
    pub diffusion_fa: Option<bool>,
    pub clip_on_cpu: Option<bool>,
    pub vae_on_cpu: Option<bool>,
    pub vae_tiling: Option<bool>,
    pub max_vram: Option<f64>,
    pub sampler: String,
    pub steps: Option<i32>,
    pub cfg_scale: Option<f64>,
    pub guidance: Option<f64>,
    pub width: Option<i32>,
    pub height: Option<i32>,
}

impl Preset {
    pub fn new_default(id: String, model: String, model_type: String) -> Self {
        Self {
            id,
            model,
            model_type,
            mmap: Some(true),
            diffusion_fa: Some(true),
            sampler: "euler_a".into(),
            steps: Some(20),
            cfg_scale: Some(7.0),
            width: Some(512),
            height: Some(512),
            ..Default::default()
        }
    }

    fn from_keys(id: &str, k: &std::collections::BTreeMap<String, String>) -> Self {
        let standalone = k.get("diffusion-model").map(|s| !s.is_empty()).unwrap_or(false);
        let model = if standalone {
            k.get("diffusion-model").cloned().unwrap_or_default()
        } else {
            k.get("model").cloned().unwrap_or_default()
        };
        let model_type = if standalone { "standalone" } else { "allinone" }.into();
        let get = |key: &str| k.get(key).cloned().unwrap_or_default();
        let getb = |key: &str| k.get(key).and_then(|v| ini::parse_bool(v));
        Self {
            id: id.to_string(),
            model,
            model_type,
            vae: get("vae"),
            llm: get("llm"),
            t5xxl: get("t5xxl"),
            clip_l: get("clip_l"),
            clip_g: get("clip_g"),
            lora_dir: get("lora-model-dir"),
            embd_dir: get("embd-dir"),
            weight_type: get("type"),
            offload_to_cpu: getb("offload-to-cpu"),
            mmap: getb("mmap"),
            fa: getb("fa"),
            diffusion_fa: getb("diffusion-fa"),
            clip_on_cpu: getb("clip-on-cpu"),
            vae_on_cpu: getb("vae-on-cpu"),
            vae_tiling: getb("vae-tiling"),
            max_vram: k.get("max-vram").and_then(|v| ini::parse_float(v)),
            sampler: get("sampler"),
            steps: k.get("steps").and_then(|v| ini::parse_int(v)),
            cfg_scale: k.get("cfg-scale").and_then(|v| ini::parse_float(v)),
            guidance: k.get("guidance").and_then(|v| ini::parse_float(v)),
            width: k.get("width").and_then(|v| ini::parse_int(v)),
            height: k.get("height").and_then(|v| ini::parse_int(v)),
        }
    }
}

pub fn load_all() -> Vec<Preset> {
    let path = paths::presets_ini();
    ini::read_all(&path)
        .into_iter()
        .map(|s| Preset::from_keys(&s.id, &s.keys))
        .collect()
}

pub fn save(preset: &Preset) -> io::Result<()> {
    let path = paths::presets_ini();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let body = render_section(preset);
    ini::replace_section(&path, &preset.id, &body)?;
    // Also touch ModelsDir in server.ini so run-server / the next config run
    // sees the updated default.
    if let Some(models_dir) = infer_models_dir(&preset.model) {
        let _ = ini::replace_key(&paths::server_ini(), "Server", "ModelsDir", &models_dir);
    }
    Ok(())
}

pub fn delete(id: &str) -> io::Result<()> {
    let path = paths::presets_ini();
    ini::delete_section(&path, id)
}

/// Derive a filesystem-safe id from a model file path: basename, sans
/// extension, sans multi-shard suffix, with non-alphanum collapsed to `_`.
/// Matches the PS helper Get-ModelId.
pub fn make_id(model_path: &str) -> String {
    let stem = std::path::Path::new(model_path)
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    // Strip -NNNNN-of-NNNNN shard suffix.
    let stem = strip_shard_suffix(&stem);
    let mut out = String::with_capacity(stem.len());
    let mut prev_underscore = false;
    for c in stem.chars() {
        let keep = c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_';
        if keep {
            out.push(c);
            prev_underscore = false;
        } else if !prev_underscore {
            out.push('_');
            prev_underscore = true;
        }
    }
    out.trim_matches('_').to_string()
}

fn strip_shard_suffix(stem: &str) -> String {
    // matches `-\d{5}-of-\d{5}$`
    if stem.len() < 12 {
        return stem.to_string();
    }
    let tail = &stem[stem.len() - 12..];
    let bytes = tail.as_bytes();
    if bytes[0] == b'-'
        && bytes[1..6].iter().all(|b| b.is_ascii_digit())
        && &bytes[6..10] == b"-of-"
        && bytes[10..].len() == 0 // unreachable, kept for clarity
    {
        return stem[..stem.len() - 12].to_string();
    }
    // Cleaner check using strip_suffix patterns:
    if let Some(prefix) = stem.rsplit_once("-of-") {
        let (head, tail) = prefix;
        if tail.len() == 5 && tail.chars().all(|c| c.is_ascii_digit()) {
            if let Some(idx) = head.rfind('-') {
                let counter = &head[idx + 1..];
                if counter.len() == 5 && counter.chars().all(|c| c.is_ascii_digit()) {
                    return head[..idx].to_string();
                }
            }
        }
    }
    stem.to_string()
}

fn infer_models_dir(model_path: &str) -> Option<String> {
    let p = PathBuf::from(model_path);
    // Walk up until we hit a folder that doesn't look like a sub-bucket.
    // Simple heuristic: parent of the file is good enough as ModelsDir.
    p.parent().map(|p| p.to_string_lossy().into_owned())
}

pub fn render_section(p: &Preset) -> String {
    let mut out = String::new();
    out.push_str(&format!("[{}]\r\n", p.id));
    out.push_str("; Generated by sd-config.\r\n");
    out.push_str("; Re-running the wizard rewrites this section; hand-edits to OTHER sections\r\n");
    out.push_str("; in this file are preserved. To add exotic sd-server flags, edit by hand and\r\n");
    out.push_str("; do not re-run the wizard for this preset.\r\n\r\n");

    if p.model_type == "allinone" {
        out.push_str("; All-in-one bundle (-m).\r\n");
        out.push_str(&format!("model = {}\r\n", p.model));
    } else {
        out.push_str("; Standalone diffusion model (--diffusion-model).\r\n");
        out.push_str(&format!("diffusion-model = {}\r\n", p.model));
    }
    out.push_str("\r\n; Sub-model paths\r\n");
    emit_str(&mut out, "vae", &p.vae);
    emit_str(&mut out, "llm", &p.llm);
    emit_str(&mut out, "t5xxl", &p.t5xxl);
    emit_str(&mut out, "clip_l", &p.clip_l);
    emit_str(&mut out, "clip_g", &p.clip_g);
    emit_str(&mut out, "lora-model-dir", &p.lora_dir);
    emit_str(&mut out, "embd-dir", &p.embd_dir);

    out.push_str("\r\n; Memory / performance\r\n");
    emit_str(&mut out, "type", &p.weight_type);
    emit_bool(&mut out, "offload-to-cpu", p.offload_to_cpu);
    emit_bool(&mut out, "mmap", p.mmap);
    emit_bool(&mut out, "fa", p.fa);
    emit_bool(&mut out, "diffusion-fa", p.diffusion_fa);
    emit_bool(&mut out, "clip-on-cpu", p.clip_on_cpu);
    emit_bool(&mut out, "vae-on-cpu", p.vae_on_cpu);
    emit_bool(&mut out, "vae-tiling", p.vae_tiling);
    emit_f64(&mut out, "max-vram", p.max_vram);

    out.push_str("\r\n; Default generation params (web UI can override per request)\r\n");
    emit_str(&mut out, "sampler", &p.sampler);
    emit_i32(&mut out, "steps", p.steps);
    emit_f64(&mut out, "cfg-scale", p.cfg_scale);
    emit_f64(&mut out, "guidance", p.guidance);
    emit_i32(&mut out, "width", p.width);
    emit_i32(&mut out, "height", p.height);
    out
}

fn emit_str(out: &mut String, key: &str, val: &str) {
    if !val.trim().is_empty() {
        out.push_str(&format!("{key} = {val}\r\n"));
    }
}
fn emit_bool(out: &mut String, key: &str, val: Option<bool>) {
    if let Some(v) = val {
        out.push_str(&format!("{key} = {}\r\n", if v { "true" } else { "false" }));
    }
}
fn emit_f64(out: &mut String, key: &str, val: Option<f64>) {
    if let Some(v) = val {
        out.push_str(&format!("{key} = {v}\r\n"));
    }
}
fn emit_i32(out: &mut String, key: &str, val: Option<i32>) {
    if let Some(v) = val {
        out.push_str(&format!("{key} = {v}\r\n"));
    }
}

/// Scan the models folder for .gguf / .safetensors files (recursive). For
/// multi-shard models only return the first shard. Matches what
/// the sd-config GUI's preset picker uses.
#[allow(dead_code)] // surfaced for future "Add preset" picker logic
pub fn scan_models() -> Vec<PathBuf> {
    let dir = server_cfg::load()
        .models_dir
        .filter(|s| !s.is_empty())
        .unwrap_or_else(server_cfg::default_models_dir);
    let mut out = Vec::new();
    walk(&PathBuf::from(dir), &mut out);
    out.sort();
    out
}

fn walk(dir: &PathBuf, out: &mut Vec<PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out);
        } else if let Some(ext) = p.extension().and_then(|s| s.to_str()) {
            let ext = ext.to_ascii_lowercase();
            if ext == "gguf" || ext == "safetensors" {
                let name = p.file_name().and_then(|s| s.to_str()).unwrap_or("");
                if is_first_shard_or_unsharded(name) {
                    out.push(p);
                }
            }
        }
    }
}

fn is_first_shard_or_unsharded(name: &str) -> bool {
    let stem = std::path::Path::new(name)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("");
    // `-NNNNN-of-NNNNN` shard?
    if let Some((head, total)) = stem.rsplit_once("-of-") {
        if total.len() == 5
            && total.chars().all(|c| c.is_ascii_digit())
            && head.len() >= 6
            && head[head.len() - 5..].chars().all(|c| c.is_ascii_digit())
            && &head[head.len() - 6..head.len() - 5] == "-"
        {
            // Only keep first shard (`-00001-of-XXXXX`).
            return &head[head.len() - 5..] == "00001";
        }
    }
    true
}
