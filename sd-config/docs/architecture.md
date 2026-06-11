# sd-config architecture

## File layout

```
sd-config/
├── Cargo.toml
├── build.rs                  # Slint compiler + Windows resource embedding
├── ui/
│   └── app.slint             # single-file Slint UI (Server / Models / MCP tabs)
└── src/
    ├── main.rs               # entry point + dual-mode dispatch
    ├── cli.rs                # clap subcommands (headless CLI)
    ├── gui.rs                # Slint callback wiring + bind-to combo
    ├── server_cfg.rs         # server.ini schema and IO
    ├── presets.rs            # presets.ini schema and per-section rewrite
    ├── mcp.rs                # per-client JSON edit (Claude Code / Desktop / OpenCode)
    ├── ini.rs                # INI dialect shared with common-functions.ps1
    ├── paths.rs              # resolve config files + mcp-server.ps1 location
    ├── net_ifaces.rs         # IPv4 interface enumeration for the bind-to combo
    ├── model_scan.rs         # ModelsDir scan backing the Models-tab dropdowns
    ├── runstate.rs           # run\sd-server.state probe (footer pill) + Stop Server action
    └── server_version.rs     # sd-server --version probe for the About dialog
```

## Dual-mode entry

`main.rs` inspects `argv`:

- `len() <= 1` → call `gui::run()` directly.
- Otherwise → on Windows release builds, `AttachConsole(ATTACH_PARENT_PROCESS)`
  so the parent shell receives `stdout`/`stderr`, then dispatch through
  `clap`-generated `cli::Cli`.

On Windows release builds, the binary uses `windows_subsystem = "windows"`,
which suppresses the console window for GUI launches. Console attachment is
deferred to CLI mode only.

## INI write contract

`ini.rs` mirrors the read-side helpers in `resources\common-functions.ps1`
(`Read-ServerIni`, `Get-Presets`). On top of read helpers, the Rust side adds
`replace_section`, which rewrites one section in place while preserving every
other section byte-for-byte. This is the same contract the retired
`config-model.ps1` wizard enforced: hand-edits to a section never touched by
the current operation must survive.

`server.ini` and `presets.ini` are written UTF-8 without BOM (a leading BOM
found on read — e.g. from a PS 5.1 `Out-File` hand-edit — is stripped and not
re-written). Read errors other than file-not-found (invalid UTF-8, sharing
violations) propagate to the caller instead of being treated as an empty
file, so a save can never silently rebuild presets.ini from a single section.

## Paths resolution

`paths::mcp_server_script()` resolves `mcp-server.ps1` by walking up from
`current_exe()`, which makes the binary work in two layouts:

- **Installed**: `$INSTDIR\bin\sd-config.exe` → `$INSTDIR\mcp-server.ps1`
- **In-tree**: `sd-config\target\release\sd-config.exe` → `<repo>\resources\mcp-server.ps1`

Other paths (`paths::server_ini`, `paths::presets_ini`, etc.) resolve under
`%LOCALAPPDATA%\stable-diffusion.cpp\config\`.

## Bind-to combo

The Server tab's "Bind to" picker is populated at GUI startup from
`net_ifaces::list_options()`, which calls `if-addrs::get_if_addrs()` and emits:

1. `localhost (only this machine)` → value `localhost`
2. `0.0.0.0 (all interfaces, LAN-reachable)` → value `0.0.0.0`
3. One row per IPv4 interface: `<ip> (<adapter name> — <network>/<prefix>)`,
   stored as the bare IP. Loopback (127/8) and APIPA link-local (169.254/16)
   are filtered out.

The combo is wired through three parallel Slint properties because Slint's
`ComboBox.model` only accepts `[string]` — label and value can't share one
struct array:

```slint
in-out property <[string]> bind_labels;   // what the dropdown shows
in-out property <[string]> bind_values;   // hostname or IP written to server.ini
in-out property <int>      bind_index;    // current selection
```

`gui::populate_bind_options` reconciles the saved hostname against the live
list. If `server.ini`'s `Hostname` is an IP that no current adapter carries —
e.g. the laptop moved to a different network — a synthetic
`<ip> (no longer present)` row is prepended so the value isn't silently
dropped on the next save.

`run-server.ps1` maps the stored value to `--listen-ip` as follows:
`localhost` → `127.0.0.1`; anything else (the literal `0.0.0.0` or a specific
interface IP) passes through verbatim.

## Dependencies

- **slint** (`unstable-winit-030`) — UI toolkit. Pinned at `1.10` in
  `Cargo.toml`, but cargo resolves to the latest 1.x; 1.16 at time of writing.
- **clap** (`derive`) — CLI argument parsing.
- **serde / serde_json** (`preserve_order`) — JSON IO for MCP client configs.
  `preserve_order` keeps user-authored key ordering intact across writes.
- **anyhow** — error type for CLI/GUI flows.
- **rfd** (`default-features = false`, no GTK) — native Win32 file/folder
  dialogs. The Common-Controls-v6 manifest it needs is embedded at build time
  by `build.rs` via winresource (see the note there), not via an rfd feature.
- **ico** — runtime .ico parsing for the title-bar icon (see
  [icon-wiring.md](icon-wiring.md)).
- **if-addrs** — IPv4/IPv6 interface enumeration for the bind-to combo.
- **winresource** (build-only, Windows) — embeds the `.ico` into the EXE's
  resource fork.

## Release profile

`[profile.release]` is tuned for a small binary: `opt-level = "z"`,
`lto = "thin"`, `codegen-units = 1`, `strip = "symbols"`.

The crate declares an empty `[workspace]` so a bare `cargo build` from the
repo root doesn't pull it into a parent workspace by accident.
