// sd-config — GUI + CLI configurator for stable-diffusion.cpp.
//
//   sd-config                  → GUI
//   sd-config <subcommand> ... → headless CLI (clap-defined in cli.rs)
//
// Suppress the console window in release on Windows when launched as GUI;
// when launched with CLI args we attach to the parent console manually.

#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

mod cli;
mod gui;
mod ini;
mod mcp;
mod net_ifaces;
mod paths;
mod presets;
mod server_cfg;

use clap::Parser;

fn main() {
    let argv: Vec<String> = std::env::args().collect();
    // No args (double-click, Start Menu shortcut) → GUI directly.
    if argv.len() <= 1 {
        if let Err(e) = gui::run() {
            eprintln!("GUI error: {e:#}");
            std::process::exit(1);
        }
        return;
    }

    // CLI mode: ensure stdout/stderr land on the parent console on Windows
    // when the binary is the GUI subsystem.
    #[cfg(all(not(debug_assertions), target_os = "windows"))]
    unsafe {
        attach_parent_console();
    }

    let cli = cli::Cli::parse();
    if let Err(e) = cli::run(cli) {
        eprintln!("Error: {e:#}");
        std::process::exit(1);
    }
}

#[cfg(all(not(debug_assertions), target_os = "windows"))]
unsafe fn attach_parent_console() {
    // Direct WinAPI to avoid pulling in a crate just for this.
    #[link(name = "kernel32")]
    extern "system" {
        fn AttachConsole(dw_process_id: u32) -> i32;
    }
    const ATTACH_PARENT_PROCESS: u32 = u32::MAX; // -1
    AttachConsole(ATTACH_PARENT_PROCESS);
}
