// Headless CLI dispatcher. Invoked when sd-config.exe is run with any
// argument; without arguments main() jumps to the GUI instead.

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};

use crate::{mcp, paths, presets, server_cfg};

#[derive(Parser, Debug)]
#[command(
    name = "sd-config",
    version,
    about = "Configure stable-diffusion.cpp: sd-server, model presets, and MCP clients. Run with no args for the GUI."
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Force-launch the GUI (default when no subcommand is given).
    Gui,
    /// Server-wide settings (server.ini).
    #[command(subcommand)]
    Server(ServerCmd),
    /// Per-model presets (presets.ini).
    #[command(subcommand)]
    Preset(PresetCmd),
    /// Register / unregister the MCP server with a client.
    #[command(subcommand)]
    Mcp(McpCmd),
}

#[derive(Subcommand, Debug)]
pub enum ServerCmd {
    /// Print the current server.ini values.
    Show,
    /// Update one or more server.ini fields.
    Set(ServerSet),
}

#[derive(Args, Debug)]
pub struct ServerSet {
    #[arg(long)]
    pub port: Option<i32>,
    #[arg(long)]
    pub hostname: Option<String>,
    /// Thread count for sd-server (`-t`). Pass 0 to unset.
    #[arg(long)]
    pub threads: Option<i32>,
    #[arg(long)]
    pub models_dir: Option<String>,
}

#[derive(Subcommand, Debug)]
pub enum PresetCmd {
    /// List preset ids and the resolved model path for each.
    List,
    /// Dump one preset as INI.
    Show { id: String },
    /// Delete a preset section.
    Delete { id: String },
}

#[derive(Subcommand, Debug)]
pub enum McpCmd {
    /// Show install state for every supported client.
    Status,
    /// Install the `stable-diffusion-cpp` entry into the given client.
    Install {
        #[arg(value_parser = ["claude-code", "claude-desktop", "opencode", "all"])]
        client: String,
        /// Override the config file path (otherwise the default for the client).
        #[arg(long)]
        config_path: Option<std::path::PathBuf>,
    },
    /// Remove the `stable-diffusion-cpp` entry from the given client.
    Uninstall {
        #[arg(value_parser = ["claude-code", "claude-desktop", "opencode", "all"])]
        client: String,
    },
}

pub fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Command::Gui => crate::gui::run().map_err(|e| anyhow::anyhow!("{e:#}")),
        Command::Server(c) => run_server(c),
        Command::Preset(c) => run_preset(c),
        Command::Mcp(c) => run_mcp(c),
    }
}

fn run_server(c: ServerCmd) -> Result<()> {
    match c {
        ServerCmd::Show => {
            let cfg = server_cfg::load();
            println!("server.ini: {}", paths::server_ini().display());
            println!("  Port:       {}", cfg.port.map_or("-".into(), |v| v.to_string()));
            println!("  Hostname:   {}", cfg.hostname.unwrap_or_else(|| "-".into()));
            println!(
                "  Threads:    {}",
                cfg.threads
                    .map_or_else(|| "auto (sd-server picks physical-core count)".into(), |v| v.to_string()),
            );
            println!("  ModelsDir:  {}", cfg.models_dir.unwrap_or_else(|| "-".into()));
            Ok(())
        }
        ServerCmd::Set(s) => {
            let mut cfg = server_cfg::load();
            if let Some(p) = s.port {
                cfg.port = Some(p);
            }
            if let Some(h) = s.hostname {
                cfg.hostname = Some(h);
            }
            if let Some(t) = s.threads {
                cfg.threads = if t > 0 { Some(t) } else { None };
            }
            if let Some(d) = s.models_dir {
                cfg.models_dir = Some(d);
            }
            server_cfg::save(&cfg).context("save server.ini")?;
            println!("Wrote {}", paths::server_ini().display());
            Ok(())
        }
    }
}

fn run_preset(c: PresetCmd) -> Result<()> {
    match c {
        PresetCmd::List => {
            let presets = presets::load_all();
            println!("presets.ini: {}", paths::presets_ini().display());
            if presets.is_empty() {
                println!("  (no presets defined)");
            }
            for p in presets {
                println!("  [{}]  type={}  model={}", p.id, p.model_type, p.model);
            }
            Ok(())
        }
        PresetCmd::Show { id } => {
            let presets = presets::load_all();
            let Some(p) = presets.iter().find(|p| p.id == id) else {
                anyhow::bail!("No preset named `{id}`. Run `sd-config preset list`.");
            };
            // Re-emit via the same renderer used on save (round-trip-clean).
            println!("{}", presets::render_section(p));
            Ok(())
        }
        PresetCmd::Delete { id } => {
            presets::delete(&id).context("delete preset")?;
            println!("Removed [{id}] from {}", paths::presets_ini().display());
            Ok(())
        }
    }
}

fn run_mcp(c: McpCmd) -> Result<()> {
    match c {
        McpCmd::Status => {
            for s in mcp::detect_all() {
                let mark = if s.installed { "✓" } else { " " };
                println!("[{mark}] {}", s.label);
                println!("    {}", s.config_path.display());
                if !s.note.is_empty() {
                    println!("    ! {}", s.note);
                }
            }
            Ok(())
        }
        McpCmd::Install { client, config_path } => {
            let ids = expand_client_arg(&client);
            for id in ids {
                if let Some(p) = config_path.as_ref() {
                    mcp::install_at(id, p)?;
                    println!("Installed {} into {}", id.id_str(), p.display());
                } else {
                    mcp::install(id)?;
                    println!("Installed {} into {}", id.id_str(), id.config_path().display());
                }
            }
            Ok(())
        }
        McpCmd::Uninstall { client } => {
            let ids = expand_client_arg(&client);
            for id in ids {
                mcp::uninstall(id)?;
                println!("Removed {} entry from {}", id.id_str(), id.config_path().display());
            }
            Ok(())
        }
    }
}

fn expand_client_arg(arg: &str) -> Vec<mcp::ClientId> {
    if arg == "all" {
        mcp::ClientId::all().to_vec()
    } else {
        match mcp::ClientId::from_str(arg) {
            Some(id) => vec![id],
            None => vec![],
        }
    }
}
