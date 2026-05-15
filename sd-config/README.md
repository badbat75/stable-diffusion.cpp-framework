# sd-config

GUI + CLI configurator for the `stable-diffusion.cpp` Windows distribution.
Produces a single dual-mode binary `sd-config.exe`:

- **No arguments** → opens the Slint GUI (three tabs: Server / Models / MCP).
- **With a subcommand** → runs headless and prints to the parent shell.

It writes the same files that `resources\run-server.ps1` and
`resources\mcp-server.ps1` read at runtime, plus the MCP-client config files
of supported AI assistants.

## What it writes

| File | Path | Purpose |
|------|------|---------|
| `server.ini`  | `%LOCALAPPDATA%\stable-diffusion.cpp\config\server.ini`  | Machine-wide sd-server settings (port, bind address, threads, models dir). Single `[Server]` section. |
| `presets.ini` | `%LOCALAPPDATA%\stable-diffusion.cpp\config\presets.ini` | One `[<preset-id>]` section per model file. Rewritten one section at a time so hand-edits to other sections survive. |
| `~/.claude.json` | `%USERPROFILE%\.claude.json` | Claude Code MCP registration (only the `stable-diffusion-cpp` key is touched). |
| `claude_desktop_config.json` | `%APPDATA%\Claude\claude_desktop_config.json` | Claude Desktop MCP registration. |
| `opencode.json` | `%USERPROFILE%\.config\opencode\opencode.json` | OpenCode MCP registration. |

The Server tab's "Bind to" combo lists `localhost`, `0.0.0.0`, and one row per
detected IPv4 interface (filtered to drop loopback and 169.254/16 link-local).
The value stored in `server.ini` is the bare hostname or IP, which
`run-server.ps1` passes verbatim to `sd-server --listen-ip`.

## Building

Prerequisites: a working `cargo` on PATH. Get it with `winget install Rustlang.Rustup` if needed.

```powershell
# From the repo root
.\03-build-gui.ps1

# Or directly
cd sd-config
cargo build --release
```

Output: `sd-config\target\release\sd-config.exe`.

`04-package.ps1` invokes `03-build-gui.ps1` lazily if `sd-config.exe` is
missing, then stages it next to `sd-server.exe` for the NSIS installer.

## CLI reference

```text
sd-config gui                              # force GUI (same as no args)

sd-config server show                      # dump current server.ini
sd-config server set --port 1234 \
                    --hostname 0.0.0.0 \
                    --threads 8 \
                    --models-dir C:\models

sd-config preset list                      # one line per preset
sd-config preset show <id>                 # round-trippable INI dump
sd-config preset delete <id>               # remove one section, keep the rest

sd-config mcp status                       # install state per supported client
sd-config mcp install   <client>           # surgical insert; preserves siblings
sd-config mcp uninstall <client>           # remove only the stable-diffusion-cpp key
```

Valid `<client>` values: `claude-code`, `claude-desktop`, `opencode`, `all`.

The `--hostname` flag currently only accepts `localhost` or `0.0.0.0`. Use the
GUI to bind to a specific interface IP.

## How it boots

On Windows the binary is built with `windows_subsystem = "windows"` in release
mode so launching it from Explorer / Start Menu doesn't pop a console. When
the binary is invoked with CLI arguments, `main.rs` calls
`AttachConsole(ATTACH_PARENT_PROCESS)` so `stdout`/`stderr` land back on the
calling shell.

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — module layout, INI write contract, paths resolution, bind-to combo wiring.
- [`docs/icon-wiring.md`](docs/icon-wiring.md) — why the icon is wired up twice and how to debug stale Explorer caches.
- [`docs/mcp-clients.md`](docs/mcp-clients.md) — per-client JSON shapes and the surgical-edit contract.
