// Reads `%LOCALAPPDATA%\stable-diffusion.cpp\run\sd-server.state` — the JSON
// that `run-server.ps1` writes while sd-server is alive. The GUI uses this to
// drive the footer status pill so users see whether sd-server is currently
// running and which preset/model is loaded.
//
// The state file is removed in run-server.ps1's `finally` block on graceful
// shutdown, but a hard kill (taskkill /f, BSOD, power loss) leaves it stale —
// so we cross-check the recorded PID against the live process table before
// reporting "running". Only `pid` + `preset` are consumed here; the file also
// carries host/port/server_exe/started_at, which serde silently ignores.
//
// `stop()` powers the App menu's "Stop Server" item: it terminates the
// recorded PID, but only after confirming that PID still resolves to an
// `sd-server.exe` image — so a recycled PID belonging to some unrelated
// process is never killed. run-server.ps1's `finally` removes the state file
// once sd-server exits.

use serde::Deserialize;

use crate::paths;

#[derive(Debug, Clone, Deserialize)]
pub struct RunState {
    pub pid: u32,
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

// Windows process FFI shared by pid_alive / is_sd_server / terminate. The
// handle lifecycle (OpenProcess → null-check → use → CloseHandle) is wrapped
// in a small RAII guard so each caller just opens with the access right it
// needs and lets the guard close on scope exit.
#[cfg(windows)]
mod winproc {
    use std::os::raw::c_void;

    pub const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    pub const PROCESS_TERMINATE: u32 = 0x0001;
    pub const ERROR_ACCESS_DENIED: u32 = 5;

    #[link(name = "kernel32")]
    extern "system" {
        pub fn OpenProcess(desired_access: u32, inherit_handle: i32, pid: u32) -> *mut c_void;
        pub fn CloseHandle(handle: *mut c_void) -> i32;
        pub fn GetLastError() -> u32;
        pub fn TerminateProcess(handle: *mut c_void, exit_code: u32) -> i32;
        pub fn QueryFullProcessImageNameW(
            handle: *mut c_void,
            flags: u32,
            buffer: *mut u16,
            size: *mut u32,
        ) -> i32;
    }

    /// RAII wrapper around an OpenProcess handle: closes it on drop. `.0` is the
    /// raw `HANDLE`, exposed for the `extern` calls above.
    pub struct ProcessHandle(pub *mut c_void);

    impl ProcessHandle {
        /// Open `pid` for `access`. `None` if OpenProcess returns null (the
        /// caller can consult `GetLastError` to tell "gone" from "denied").
        pub fn open(pid: u32, access: u32) -> Option<ProcessHandle> {
            let h = unsafe { OpenProcess(access, 0, pid) };
            if h.is_null() {
                None
            } else {
                Some(ProcessHandle(h))
            }
        }
    }

    impl Drop for ProcessHandle {
        fn drop(&mut self) {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}

#[cfg(windows)]
fn pid_alive(pid: u32) -> bool {
    // OpenProcess with PROCESS_QUERY_LIMITED_INFORMATION returns a non-null
    // handle for any running process the caller can name. A null return with
    // ERROR_ACCESS_DENIED also implies the process exists (we just can't
    // open it) — treat that as alive too.
    use winproc::*;
    if ProcessHandle::open(pid, PROCESS_QUERY_LIMITED_INFORMATION).is_some() {
        return true;
    }
    unsafe { GetLastError() == ERROR_ACCESS_DENIED }
}

#[cfg(not(windows))]
fn pid_alive(_pid: u32) -> bool {
    // sd-config is Windows-only at runtime; this branch only exists so
    // `cargo check` succeeds when invoked on a non-Windows host.
    false
}

/// Terminate the running sd-server. Returns `Ok(true)` if a live sd-server was
/// signalled, `Ok(false)` if nothing was running (or the recorded PID has been
/// recycled to a non-sd-server process — left untouched), `Err` if the kill
/// itself failed. The PID's killing immediately makes `load()` report `None`,
/// and run-server.ps1's `finally` cleans up the state file afterwards.
pub fn stop() -> std::io::Result<bool> {
    let Some(state) = load() else {
        return Ok(false);
    };
    if !is_sd_server(state.pid) {
        // PID recycled to something else — refuse to kill it.
        return Ok(false);
    }
    terminate(state.pid)?;
    Ok(true)
}

#[cfg(windows)]
fn is_sd_server(pid: u32) -> bool {
    // Resolve the PID's full image path and check the basename, mirroring
    // run-server.ps1 / mcp-server.ps1's Test-SdServerAlive identity check so a
    // recycled PID can't be mistaken for the server.
    use winproc::*;
    let Some(h) = ProcessHandle::open(pid, PROCESS_QUERY_LIMITED_INFORMATION) else {
        return false;
    };
    let mut buf = [0u16; 260];
    let mut size: u32 = buf.len() as u32;
    let ok = unsafe { QueryFullProcessImageNameW(h.0, 0, buf.as_mut_ptr(), &mut size) };
    if ok == 0 {
        return false;
    }
    let path = String::from_utf16_lossy(&buf[..size as usize]);
    path.to_ascii_lowercase().ends_with("sd-server.exe")
}

#[cfg(windows)]
fn terminate(pid: u32) -> std::io::Result<()> {
    use winproc::*;
    let Some(h) = ProcessHandle::open(pid, PROCESS_TERMINATE) else {
        return Err(std::io::Error::last_os_error());
    };
    let ok = unsafe { TerminateProcess(h.0, 0) };
    if ok == 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(not(windows))]
fn is_sd_server(_pid: u32) -> bool {
    false
}

#[cfg(not(windows))]
fn terminate(_pid: u32) -> std::io::Result<()> {
    Ok(())
}
