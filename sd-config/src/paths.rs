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
        .expect("LOCALAPPDATA not set on Windows")
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

/// `%LOCALAPPDATA%\stable-diffusion.cpp\run\sd-server.state` — the JSON
/// `run-server.ps1` writes while sd-server is running. Consumed by the GUI's
/// status-pill refresh and by `mcp-server.ps1` for liveness detection.
pub fn run_state() -> PathBuf {
    data_root().join("run").join("sd-server.state")
}

/// `%APPDATA%\Claude\claude_desktop_config.json`
pub fn claude_desktop_config() -> PathBuf {
    env_path("APPDATA")
        .expect("APPDATA not set on Windows")
        .join("Claude")
        .join("claude_desktop_config.json")
}

/// `%USERPROFILE%\.claude.json`
pub fn claude_code_user_config() -> PathBuf {
    env_path("USERPROFILE")
        .expect("USERPROFILE not set on Windows")
        .join(".claude.json")
}

/// `%USERPROFILE%\.config\opencode\opencode.json`
///
/// OpenCode also accepts `opencode.json` in the project root; we target the
/// user-scope file here since that's what configures the editor globally.
pub fn opencode_user_config() -> PathBuf {
    env_path("USERPROFILE")
        .expect("USERPROFILE not set on Windows")
        .join(".config")
        .join("opencode")
        .join("opencode.json")
}

/// Where sd-server.exe lives. Tries (in order):
/// 1. `<exe-dir>\sd-server.exe`                                — installer layout (`$INSTDIR\bin\sd-config.exe` next to `sd-server.exe`)
/// 2. `<exe-dir>\..\..\..\build\cmake-build\bin\sd-server.exe` — dev layout (sd-config\target\release\)
/// 3. `<exe-dir>\..\build\cmake-build\bin\sd-server.exe`       — alt dev layout (sd-config\target\)
pub fn sd_server_exe() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let exe_dir = exe.parent()?;
    let candidates = [
        exe_dir.join("sd-server.exe"),
        exe_dir
            .join("..")
            .join("..")
            .join("..")
            .join("build")
            .join("cmake-build")
            .join("bin")
            .join("sd-server.exe"),
        exe_dir
            .join("..")
            .join("build")
            .join("cmake-build")
            .join("bin")
            .join("sd-server.exe"),
    ];
    for c in &candidates {
        if c.exists() {
            return c.canonicalize().ok().or_else(|| Some(c.clone()));
        }
    }
    None
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
