// Spawns `sd-server.exe --version` once at GUI startup and parses its output
// into a short string suitable for the header (e.g. "master-596-90e87bc").
//
// The probe runs on a background thread (see gui::spawn_version_probe) and
// pushes the result into the Slint property via invoke_from_event_loop —
// otherwise a slow first-time Windows EXE launch would hold up app startup.

use std::process::Command;

use crate::paths;

/// Resolve sd-server.exe and read its `--version` line. Returns `None` when
/// the binary isn't found, exits non-zero, or prints something unexpected.
pub fn probe() -> Option<String> {
    let exe = paths::sd_server_exe()?;
    let stdout = run(&exe)?;
    parse(&stdout)
}

#[cfg(windows)]
fn run(exe: &std::path::Path) -> Option<String> {
    // CREATE_NO_WINDOW so the subprocess doesn't briefly flash a console
    // window when sd-config is launched as the GUI subsystem.
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    let output = Command::new(exe)
        .arg("--version")
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

#[cfg(not(windows))]
fn run(exe: &std::path::Path) -> Option<String> {
    let output = Command::new(exe).arg("--version").output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Turn `"stable-diffusion.cpp version master-596-90e87bc, commit 90e87bc\n"`
/// into `"master-596-90e87bc"`. The commit suffix is dropped because
/// `sd_version()` is `git describe` output and already contains the commit
/// hash — repeating it is just noise in a 12px header chip.
fn parse(s: &str) -> Option<String> {
    let line = s.lines().next()?.trim();
    if line.is_empty() {
        return None;
    }
    let stripped = line
        .strip_prefix("stable-diffusion.cpp version ")
        .unwrap_or(line);
    let trimmed = stripped.split(", commit ").next().unwrap_or(stripped);
    let out = trimmed.trim();
    if out.is_empty() {
        None
    } else {
        Some(out.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn strips_prefix_and_commit_tail() {
        assert_eq!(
            parse("stable-diffusion.cpp version master-596-90e87bc, commit 90e87bc\n").as_deref(),
            Some("master-596-90e87bc"),
        );
    }

    #[test]
    fn keeps_unknown_format_verbatim() {
        assert_eq!(parse("custom-build-1.2.3\n").as_deref(), Some("custom-build-1.2.3"));
    }

    #[test]
    fn empty_input_is_none() {
        assert!(parse("").is_none());
        assert!(parse("\n").is_none());
    }
}
