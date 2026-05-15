// MCP-client integration — installs / removes the `stable-diffusion-cpp`
// entry in:
//   * Claude Code   : %USERPROFILE%\.claude.json
//   * Claude Desktop: %APPDATA%\Claude\claude_desktop_config.json
//   * OpenCode      : %USERPROFILE%\.config\opencode\opencode.json
//
// All three keep the existing JSON intact: we parse, mutate the relevant
// subtree, and write back with `preserve_order` so the user's key ordering
// survives.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::paths;

const SERVER_KEY: &str = "stable-diffusion-cpp";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClientId {
    ClaudeCode,
    ClaudeDesktop,
    OpenCode,
}

impl ClientId {
    pub fn from_str(s: &str) -> Option<Self> {
        Some(match s {
            "claude-code" => Self::ClaudeCode,
            "claude-desktop" => Self::ClaudeDesktop,
            "opencode" => Self::OpenCode,
            _ => return None,
        })
    }
    pub fn id_str(&self) -> &'static str {
        match self {
            Self::ClaudeCode => "claude-code",
            Self::ClaudeDesktop => "claude-desktop",
            Self::OpenCode => "opencode",
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::ClaudeCode => "Claude Code (user-scope ~/.claude.json)",
            Self::ClaudeDesktop => "Claude Desktop",
            Self::OpenCode => "OpenCode",
        }
    }
    pub fn config_path(&self) -> PathBuf {
        match self {
            Self::ClaudeCode => paths::claude_code_user_config(),
            Self::ClaudeDesktop => paths::claude_desktop_config(),
            Self::OpenCode => paths::opencode_user_config(),
        }
    }
    pub fn all() -> [Self; 3] {
        [Self::ClaudeCode, Self::ClaudeDesktop, Self::OpenCode]
    }
}

#[derive(Debug, Clone)]
pub struct ClientStatus {
    pub id: ClientId,
    pub label: String,
    pub config_path: PathBuf,
    pub installed: bool,
    pub note: String,
}

pub fn detect_all() -> Vec<ClientStatus> {
    ClientId::all()
        .into_iter()
        .map(|id| {
            let path = id.config_path();
            let (installed, note) = match check_installed(&path, id) {
                Ok(v) => (v, String::new()),
                Err(e) => (false, e.to_string()),
            };
            ClientStatus {
                id,
                label: id.label().to_string(),
                config_path: path,
                installed,
                note,
            }
        })
        .collect()
}

fn check_installed(path: &Path, id: ClientId) -> Result<bool> {
    if !path.exists() {
        return Ok(false);
    }
    let txt = fs::read_to_string(path).context("read config")?;
    if txt.trim().is_empty() {
        return Ok(false);
    }
    // Note: serde_json's `preserve_order` feature (Cargo.toml) is load-bearing —
    // it's what keeps user-defined keys in their original order when we
    // re-serialize after inserting our own entry. Don't drop the feature flag.
    let v: Value = serde_json::from_str(&txt).context("parse JSON")?;
    let bucket_key = bucket_key(id);
    let installed = v
        .get(bucket_key)
        .and_then(|b| b.get(SERVER_KEY))
        .is_some();
    Ok(installed)
}

fn bucket_key(id: ClientId) -> &'static str {
    match id {
        ClientId::ClaudeCode | ClientId::ClaudeDesktop => "mcpServers",
        ClientId::OpenCode => "mcp",
    }
}

fn entry_value(id: ClientId, script: &Path) -> Value {
    let script_str = script.to_string_lossy().replace('\\', "/");
    match id {
        ClientId::ClaudeCode | ClientId::ClaudeDesktop => json!({
            "command": "pwsh.exe",
            "args": [
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", script_str
            ]
        }),
        ClientId::OpenCode => json!({
            "type": "local",
            "command": [
                "pwsh.exe",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", script_str
            ],
            "enabled": true
        }),
    }
}

pub fn install(id: ClientId) -> Result<()> {
    let script = paths::mcp_server_script()
        .context("Could not find resources/mcp-server.ps1 next to sd-config.exe — install the package or run from the repo root.")?;
    let path = id.config_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create dir {}", parent.display()))?;
    }
    let mut v: Value = if path.exists() {
        let txt = fs::read_to_string(&path).context("read existing config")?;
        if txt.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(&txt).context("parse existing config as JSON")?
        }
    } else {
        Value::Object(Default::default())
    };

    let bucket = bucket_key(id);
    if !v.is_object() {
        anyhow::bail!("Top-level of {} is not an object", path.display());
    }
    let obj = v.as_object_mut().unwrap();
    let bucket_value = obj
        .entry(bucket.to_string())
        .or_insert_with(|| Value::Object(Default::default()));
    if !bucket_value.is_object() {
        anyhow::bail!("`{bucket}` in {} is not an object", path.display());
    }
    bucket_value
        .as_object_mut()
        .unwrap()
        .insert(SERVER_KEY.to_string(), entry_value(id, &script));

    let serialized = serde_json::to_string_pretty(&v)?;
    atomic_write(&path, &(serialized + "\n"))
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

pub fn uninstall(id: ClientId) -> Result<()> {
    let path = id.config_path();
    if !path.exists() {
        return Ok(());
    }
    let txt = fs::read_to_string(&path).context("read existing config")?;
    if txt.trim().is_empty() {
        return Ok(());
    }
    let mut v: Value = serde_json::from_str(&txt).context("parse existing config as JSON")?;
    let bucket = bucket_key(id);
    if let Some(b) = v.get_mut(bucket).and_then(|b| b.as_object_mut()) {
        b.remove(SERVER_KEY);
    }
    let serialized = serde_json::to_string_pretty(&v)?;
    atomic_write(&path, &(serialized + "\n"))
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

/// Manually-targeted variant: install into the given path (used by `--config-path`).
pub fn install_at(id: ClientId, path: &Path) -> Result<()> {
    let script = paths::mcp_server_script()
        .context("Could not find resources/mcp-server.ps1 next to sd-config.exe")?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create dir {}", parent.display()))?;
    }
    let mut v: Value = if path.exists() {
        let txt = fs::read_to_string(path)?;
        if txt.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(&txt)?
        }
    } else {
        Value::Object(Default::default())
    };
    let bucket = bucket_key(id);
    let obj = v.as_object_mut().context("top-level not object")?;
    let b = obj
        .entry(bucket.to_string())
        .or_insert_with(|| Value::Object(Default::default()));
    let b_obj = b.as_object_mut().context("bucket not object")?;
    b_obj.insert(SERVER_KEY.to_string(), entry_value(id, &script));
    let serialized = serde_json::to_string_pretty(&v)?;
    atomic_write(path, &(serialized + "\n"))
        .with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

/// Write JSON to disk via a temp-file + rename so a mid-write crash can't
/// truncate the user's existing config. Both files must be on the same
/// volume (always true for `<path>.tmp` next to `<path>`).
fn atomic_write(path: &Path, contents: &str) -> Result<()> {
    let tmp = path.with_extension(
        path.extension()
            .map(|e| format!("{}.tmp", e.to_string_lossy()))
            .unwrap_or_else(|| "tmp".to_string()),
    );
    fs::write(&tmp, contents).with_context(|| format!("write {}", tmp.display()))?;
    fs::rename(&tmp, path)
        .with_context(|| format!("rename {} -> {}", tmp.display(), path.display()))?;
    Ok(())
}

