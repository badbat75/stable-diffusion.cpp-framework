// Resolution of well-known Windows paths the configurator touches.
//
// Mirrors the layout run-server.ps1 / mcp-server.ps1 expect — anything new
// added here should also be reflected in AGENTS.md.

use std::path::PathBuf;

fn env_path(var: &str) -> Option<PathBuf> {
    std::env::var_os(var).map(PathBuf::from)
}

/// `%LOCALAPPDATA%\stable-diffusion.cpp`
pub fn data_root() -> PathBuf {
    env_path("LOCALAPPDATA")
        .unwrap_or_else(|| dirs::data_local_dir().unwrap_or_else(|| PathBuf::from(".")))
        .join("stable-diffusion.cpp")
}

pub fn config_dir() -> PathBuf {
    data_root().join("config")
}

pub fn server_ini() -> PathBuf {
    config_dir().join("server.ini")
}

pub fn presets_ini() -> PathBuf {
    config_dir().join("presets.ini")
}

#[allow(dead_code)] // reserved for future liveness checks against run-server.ps1
pub fn run_state() -> PathBuf {
    data_root().join("run").join("sd-server.state")
}

/// `%APPDATA%\Claude\claude_desktop_config.json`
pub fn claude_desktop_config() -> PathBuf {
    env_path("APPDATA")
        .unwrap_or_else(|| dirs::config_dir().unwrap_or_else(|| PathBuf::from(".")))
        .join("Claude")
        .join("claude_desktop_config.json")
}

/// `%USERPROFILE%\.claude.json`
pub fn claude_code_user_config() -> PathBuf {
    env_path("USERPROFILE")
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")))
        .join(".claude.json")
}

/// `%USERPROFILE%\.config\opencode\opencode.json`
///
/// OpenCode also accepts `opencode.json` in the project root; we target the
/// user-scope file here since that's what configures the editor globally.
pub fn opencode_user_config() -> PathBuf {
    env_path("USERPROFILE")
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")))
        .join(".config")
        .join("opencode")
        .join("opencode.json")
}

/// Where mcp-server.ps1 lives. Tries (in order):
/// 1. `<exe-dir>\mcp-server.ps1`                       — flat install (rare)
/// 2. `<exe-dir>\..\mcp-server.ps1`                    — installer layout ($INSTDIR\bin\ → $INSTDIR\)
/// 3. `<exe-dir>\..\..\..\resources\mcp-server.ps1`   — dev layout (sd-config\target\release\)
/// 4. `<exe-dir>\..\resources\mcp-server.ps1`         — fallback dev layout
pub fn mcp_server_script() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;
    let candidates = [
        exe_dir.join("mcp-server.ps1"),
        exe_dir.join("..").join("mcp-server.ps1"),
        exe_dir
            .join("..")
            .join("..")
            .join("..")
            .join("resources")
            .join("mcp-server.ps1"),
        exe_dir.join("..").join("resources").join("mcp-server.ps1"),
    ];
    for c in &candidates {
        if c.exists() {
            return c.canonicalize().ok().or_else(|| Some(c.clone()));
        }
    }
    None
}
