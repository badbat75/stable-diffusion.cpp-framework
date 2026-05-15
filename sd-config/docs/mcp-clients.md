# MCP client integration

The MCP tab (and `sd-config mcp install|uninstall <client>`) registers the
`stable-diffusion-cpp` server with whichever AI assistant the user runs. The
entry points at `resources\mcp-server.ps1`, resolved via `paths::mcp_server_script`.

Source: `src/mcp.rs`.

## Supported clients

| Client | Config file | JSON bucket |
|--------|-------------|-------------|
| Claude Code    | `%USERPROFILE%\.claude.json`                      | `mcpServers` |
| Claude Desktop | `%APPDATA%\Claude\claude_desktop_config.json`     | `mcpServers` |
| OpenCode       | `%USERPROFILE%\.config\opencode\opencode.json`    | `mcp`        |

## Entry shape

Claude Code and Claude Desktop expect a `command` + `args` pair:

```json
{
  "mcpServers": {
    "stable-diffusion-cpp": {
      "command": "pwsh.exe",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "C:/Program Files/stable-diffusion.cpp/mcp-server.ps1"
      ]
    }
  }
}
```

OpenCode uses a flat `command` array plus a `type` discriminator and an
`enabled` flag:

```json
{
  "mcp": {
    "stable-diffusion-cpp": {
      "type": "local",
      "command": [
        "pwsh.exe",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "C:/Program Files/stable-diffusion.cpp/mcp-server.ps1"
      ],
      "enabled": true
    }
  }
}
```

Backslashes in the script path are normalized to forward slashes so the
serialized JSON doesn't have to escape them.

## Surgical-edit contract

Install and uninstall **never rewrite the rest of the file**:

1. Parse the existing JSON with `serde_json::from_str`, with `preserve_order`
   enabled so the user's key ordering survives the round-trip.
2. Locate the right bucket (`mcpServers` or `mcp`); create it if missing.
3. Insert or remove only the `stable-diffusion-cpp` key. Every sibling key is
   left untouched.
4. Re-serialize with `serde_json::to_string_pretty` and overwrite.

`install_at(id, path)` is a manually-targeted variant exposed via
`sd-config mcp install <client> --config-path <file>` for clients that store
their config in a non-default location.

### Detection

`mcp::detect_all()` reads each client's config and reports `installed = true`
when the relevant bucket contains a `stable-diffusion-cpp` key. Errors during
parsing surface in the `note` field of `ClientStatus`, which the GUI shows in
red under the affected client card.

## Project-scope vs user-scope

For developers who clone the repo, the project-scope `.mcp.json` at the repo
root auto-registers `resources\mcp-server.ps1` for anyone who opens the repo
in Claude Code. It uses a relative path, so it works on any clone location;
Claude Code prompts to trust the project on first open.

For end-users (and contributors who want the registration to follow them
across repos), the sd-config GUI's MCP tab — or `sd-config mcp install ...`
on the command line — writes into the per-user config file directly.
