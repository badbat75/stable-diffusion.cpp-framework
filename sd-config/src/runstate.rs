// Reads `%LOCALAPPDATA%\stable-diffusion.cpp\run\sd-server.state` — the JSON
// that `run-server.ps1` writes while sd-server is alive. The GUI uses this to
// drive the header status pill so users see whether sd-server is currently
// running and on which host/port.
//
// The state file is removed in run-server.ps1's `finally` block on graceful
// shutdown, but a hard kill (taskkill /f, BSOD, power loss) leaves it stale —
// so we cross-check the recorded PID against the live process table before
// reporting "running".

use serde::Deserialize;

use crate::paths;

#[derive(Debug, Clone, Deserialize)]
pub struct RunState {
    pub pid: u32,
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub preset: String,
}

/// Returns `Some(state)` only if the state file exists, parses, **and** the
/// recorded PID is still alive. Stale files (PID gone) read as `None`.
pub fn load() -> Option<RunState> {
    let path = paths::run_state();
    let bytes = std::fs::read(&path).ok()?;
    let state: RunState = serde_json::from_slice(&bytes).ok()?;
    if !pid_alive(state.pid) {
        return None;
    }
    Some(state)
}

#[cfg(windows)]
fn pid_alive(pid: u32) -> bool {
    // OpenProcess with PROCESS_QUERY_LIMITED_INFORMATION returns a non-null
    // handle for any running process the caller can name. A null return with
    // ERROR_ACCESS_DENIED also implies the process exists (we just can't
    // open it) — treat that as alive too.
    use std::os::raw::c_void;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const ERROR_ACCESS_DENIED: u32 = 5;
    #[link(name = "kernel32")]
    extern "system" {
        fn OpenProcess(desired_access: u32, inherit_handle: i32, pid: u32) -> *mut c_void;
        fn CloseHandle(handle: *mut c_void) -> i32;
        fn GetLastError() -> u32;
    }
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if !h.is_null() {
            CloseHandle(h);
            return true;
        }
        GetLastError() == ERROR_ACCESS_DENIED
    }
}

#[cfg(not(windows))]
fn pid_alive(_pid: u32) -> bool {
    // sd-config is Windows-only at runtime; this branch only exists so
    // `cargo check` succeeds when invoked on a non-Windows host.
    false
}
