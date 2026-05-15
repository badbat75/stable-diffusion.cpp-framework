// Slint GUI wiring. Loads server.ini + presets.ini + MCP-client state at
// startup, binds every callback declared in ui/app.slint, and writes back
// through the same modules the CLI uses (server_cfg, presets, mcp).

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use slint::{ComponentHandle, Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel};
use slint::winit_030::{winit, WinitWindowAccessor};
#[cfg(windows)]
use winit::platform::windows::WindowExtWindows;

use crate::{mcp, net_ifaces, paths, presets, server_cfg};

slint::include_modules!();

#[derive(Default)]
struct State {
    presets: Vec<presets::Preset>,
}

pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    let app = AppWindow::new()?;
    let state = Rc::new(RefCell::new(State::default()));

    set_window_icon(&app);
    load_server_into_ui(&app);
    refresh_presets(&app, &state);
    refresh_mcp(&app);

    app.set_presets_path(SharedString::from(paths::presets_ini().to_string_lossy().into_owned()));

    // ── Server tab callbacks ─────────────────────────────────────────
    {
        let app_weak = app.as_weak();
        app.on_save_server(move || {
            let Some(app) = app_weak.upgrade() else { return };
            let cfg = read_server_from_ui(&app);
            match server_cfg::save(&cfg) {
                Ok(()) => set_status(&app, format!("Saved {}", paths::server_ini().display()), false),
                Err(e) => set_status(&app, format!("Save failed: {e}"), true),
            }
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_browse_models_dir(move |current| {
            let _app = app_weak.upgrade();
            let start = if !current.is_empty() {
                PathBuf::from(current.as_str())
            } else {
                PathBuf::from(server_cfg::default_models_dir())
            };
            pick_dir(&start).map(|p| SharedString::from(p.to_string_lossy().into_owned())).unwrap_or(current)
        });
    }

    // ── Models tab callbacks ─────────────────────────────────────────
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_select_preset(move |index| {
            let Some(app) = app_weak.upgrade() else { return };
            let st = state.borrow();
            if let Some(p) = usize::try_from(index).ok().and_then(|i| st.presets.get(i)) {
                app.set_selected_preset_index(index);
                app.set_form(preset_to_form(p));
            }
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_save_preset(move || {
            let Some(app) = app_weak.upgrade() else { return };
            let p = form_to_preset(&app.get_form());
            if p.id.is_empty() {
                set_status(&app, "Preset id is empty.".into(), true);
                return;
            }
            if p.model.is_empty() {
                set_status(&app, "Pick a model file before saving.".into(), true);
                return;
            }
            match presets::save(&p) {
                Ok(()) => {
                    set_status(&app, format!("Saved preset [{}]", p.id), false);
                    refresh_presets(&app, &state);
                    // Reselect the just-saved preset.
                    let st = state.borrow();
                    if let Some(i) = st.presets.iter().position(|x| x.id == p.id) {
                        app.set_selected_preset_index(i as i32);
                    }
                }
                Err(e) => set_status(&app, format!("Save failed: {e}"), true),
            }
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_delete_preset(move |id| {
            let Some(app) = app_weak.upgrade() else { return };
            if id.is_empty() {
                return;
            }
            match presets::delete(id.as_str()) {
                Ok(()) => {
                    set_status(&app, format!("Deleted [{id}]"), false);
                    refresh_presets(&app, &state);
                    app.set_selected_preset_index(-1);
                    app.set_form(blank_form());
                }
                Err(e) => set_status(&app, format!("Delete failed: {e}"), true),
            }
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_new_preset(move || {
            let Some(app) = app_weak.upgrade() else { return };
            // Open a file picker rooted at ModelsDir; user picks a .gguf / .safetensors.
            let start = server_cfg::load()
                .models_dir
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(server_cfg::default_models_dir()));
            let Some(path) = rfd::FileDialog::new()
                .set_title("Pick a model file (.gguf / .safetensors)")
                .add_filter("Model", &["gguf", "safetensors"])
                .set_directory(&start)
                .pick_file()
            else {
                return;
            };
            let id = presets::make_id(&path.to_string_lossy());
            let p = presets::Preset::new_default(
                id.clone(),
                path.to_string_lossy().into_owned(),
                "standalone".into(),
            );
            app.set_form(preset_to_form(&p));
            app.set_selected_preset_index(-1); // not in the list until saved
            set_status(&app, format!("New preset draft for [{id}] — fill in and Save."), false);
            // No write yet.
            let _ = state.borrow_mut();
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_browse_path(move |field, current| {
            let _app = app_weak.upgrade();
            let start = parent_or_models_dir(current.as_str());
            let mut dlg = rfd::FileDialog::new().set_title(&format!("Pick file for `{field}`"));
            if field == "model" {
                dlg = dlg.add_filter("Model", &["gguf", "safetensors"]);
            } else {
                dlg = dlg
                    .add_filter("Weights", &["gguf", "safetensors", "bin", "pth", "pt"])
                    .add_filter("Any", &["*"]);
            }
            dlg.set_directory(&start)
                .pick_file()
                .map(|p| SharedString::from(p.to_string_lossy().into_owned()))
                .unwrap_or(current)
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_browse_dir(move |_field, current| {
            let _app = app_weak.upgrade();
            let start = if !current.is_empty() {
                PathBuf::from(current.as_str())
            } else {
                PathBuf::from(server_cfg::default_models_dir())
            };
            pick_dir(&start)
                .map(|p| SharedString::from(p.to_string_lossy().into_owned()))
                .unwrap_or(current)
        });
    }

    // ── MCP tab callbacks ─────────────────────────────────────────────
    {
        let app_weak = app.as_weak();
        app.on_mcp_install(move |id| {
            let Some(app) = app_weak.upgrade() else { return };
            let Some(cid) = mcp::ClientId::from_str(id.as_str()) else { return };
            match mcp::install(cid) {
                Ok(()) => set_status(&app, format!("Installed: {}", cid.config_path().display()), false),
                Err(e) => set_status(&app, format!("Install failed: {e:#}"), true),
            }
            refresh_mcp(&app);
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_mcp_uninstall(move |id| {
            let Some(app) = app_weak.upgrade() else { return };
            let Some(cid) = mcp::ClientId::from_str(id.as_str()) else { return };
            match mcp::uninstall(cid) {
                Ok(()) => set_status(&app, format!("Removed: {}", cid.config_path().display()), false),
                Err(e) => set_status(&app, format!("Uninstall failed: {e:#}"), true),
            }
            refresh_mcp(&app);
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_mcp_refresh(move || {
            let Some(app) = app_weak.upgrade() else { return };
            refresh_mcp(&app);
            set_status(&app, "Re-detected.".into(), false);
        });
    }

    app.run()?;
    Ok(())
}

// ── Helpers ──────────────────────────────────────────────────────────

// Title-bar / Alt+Tab / taskbar icon for the running window.
//
// Two paths, intentionally:
//
// 1. Slint property `window_icon` bound to `Window.icon` in app.slint — kept
//    in case a future Slint adds OS-window propagation through this property.
//    Today (1.16) the WindowProperties surface exposed to backends does NOT
//    include `icon`, so this binding alone has no visible effect.
//
// 2. The actually-load-bearing path: bypass Slint and reach the underlying
//    winit::window::Window via `WinitWindowAccessor::with_winit_window` and
//    call `set_window_icon` directly. The winit window doesn't exist until
//    `app.run()` starts the event loop, so we defer through a 0-duration
//    Timer that fires on the first event-loop iteration after `show()`.
//
// The same .ico is also embedded into the EXE's resource fork by build.rs
// (winresource), which handles Explorer / Start Menu (after Windows refreshes
// its icon cache — kill `explorer.exe` and restart it to force-refresh, or
// reboot, if the EXE used to ship without the resource and the cache is
// stale). This runtime path covers the live-window icon regardless.
fn set_window_icon(app: &AppWindow) {
    const ICON_BYTES: &[u8] = include_bytes!("../../resources/stable-diffusion.ico");

    // Pick two distinct frames out of the .ico:
    //   * small (~32x32) for ICON_SMALL → title bar / system menu
    //   * big   (~256x256) for ICON_BIG → taskbar / Alt-Tab
    // winit on Windows 0.30 routes `set_window_icon` to ICON_SMALL only and
    // `set_taskbar_icon` to ICON_BIG; we feed each its preferred size to
    // avoid Windows downsampling 256×256 down to a blurry 16-pixel title-bar
    // glyph.
    let small = decode_ico_frame_near(ICON_BYTES, 32);
    let big = decode_ico_frame_near(ICON_BYTES, 256);

    // Slint property mirror — bound to Window.icon, currently a no-op at the
    // OS level (1.16) but harmless.
    if let Some((rgba, w, h)) = big.as_ref().or(small.as_ref()) {
        let buffer = SharedPixelBuffer::<Rgba8Pixel>::clone_from_slice(rgba, *w, *h);
        app.set_window_icon(Image::from_rgba8(buffer));
    }

    let app_weak = app.as_weak();
    // Defer until app.run() has created the underlying winit window.
    slint::Timer::single_shot(std::time::Duration::from_millis(50), move || {
        let Some(app) = app_weak.upgrade() else { return };
        app.window().with_winit_window(|win| {
            if let Some((rgba, w, h)) = small {
                if let Ok(icon) = winit::window::Icon::from_rgba(rgba, w, h) {
                    win.set_window_icon(Some(icon)); // ICON_SMALL → title bar
                }
            }
            if let Some((rgba, w, h)) = big {
                if let Ok(icon) = winit::window::Icon::from_rgba(rgba, w, h) {
                    win.set_taskbar_icon(Some(icon)); // ICON_BIG  → taskbar
                }
            }
        });
    });
}

/// Decode a single frame out of an .ico, picking the entry whose width is
/// closest to `target_size`. Returns RGBA8 + dimensions.
fn decode_ico_frame_near(ico_bytes: &[u8], target_size: u32) -> Option<(Vec<u8>, u32, u32)> {
    let dir = ico::IconDir::read(std::io::Cursor::new(ico_bytes)).ok()?;
    let entry = dir
        .entries()
        .iter()
        .min_by_key(|e| (e.width() as i64 - target_size as i64).abs())?;
    let img = entry.decode().ok()?;
    let w = img.width();
    let h = img.height();
    let rgba = img.rgba_data().to_vec();
    Some((rgba, w, h))
}

fn pick_dir(start: &std::path::Path) -> Option<PathBuf> {
    rfd::FileDialog::new()
        .set_title("Pick a folder")
        .set_directory(start)
        .pick_folder()
}

fn parent_or_models_dir(current: &str) -> PathBuf {
    if !current.is_empty() {
        let p = PathBuf::from(current);
        if let Some(parent) = p.parent() {
            return parent.to_path_buf();
        }
    }
    server_cfg::load()
        .models_dir
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(server_cfg::default_models_dir()))
}

fn set_status(app: &AppWindow, text: String, is_error: bool) {
    app.set_status_text(SharedString::from(text));
    app.set_status_is_error(is_error);
}

fn load_server_into_ui(app: &AppWindow) {
    let cfg = server_cfg::load();
    app.set_server_port(SharedString::from(
        cfg.port.map(|v| v.to_string()).unwrap_or_else(|| "1234".into()),
    ));
    let hostname = cfg.hostname.unwrap_or_else(|| "localhost".into());
    populate_bind_options(app, &hostname);
    app.set_server_hostname(SharedString::from(hostname));
    app.set_server_threads(SharedString::from(
        cfg.threads.map(|v| v.to_string()).unwrap_or_default(),
    ));
    app.set_server_models_dir(SharedString::from(
        cfg.models_dir.unwrap_or_else(server_cfg::default_models_dir),
    ));
}

// Build the Bind-to combo's model. The list is built every startup so newly
// added/removed adapters show up without restarting only on next launch — a
// per-frame rebuild would fight ComboBox's current-index. If the saved
// hostname is an IP that no adapter currently carries (e.g. user took the
// laptop to a different network), we prepend a synthetic row labelled as
// "no longer present" so the user can still see and keep their choice.
fn populate_bind_options(app: &AppWindow, current: &str) {
    let mut opts = net_ifaces::list_options();
    let mut index = opts.iter().position(|o| o.value == current);
    if index.is_none() && !current.is_empty() {
        opts.insert(
            2, // after localhost and 0.0.0.0
            net_ifaces::BindOption {
                label: format!("{current} (no longer present)"),
                value: current.to_string(),
            },
        );
        index = Some(2);
    }
    let labels: Vec<SharedString> = opts.iter().map(|o| o.label.clone().into()).collect();
    let values: Vec<SharedString> = opts.iter().map(|o| o.value.clone().into()).collect();
    app.set_bind_labels(ModelRc::from(Rc::new(VecModel::from(labels))));
    app.set_bind_values(ModelRc::from(Rc::new(VecModel::from(values))));
    app.set_bind_index(index.unwrap_or(0) as i32);
}

fn read_server_from_ui(app: &AppWindow) -> server_cfg::ServerConfig {
    server_cfg::ServerConfig {
        port: parse_int(app.get_server_port().as_str()),
        hostname: Some(app.get_server_hostname().to_string()),
        threads: parse_int(app.get_server_threads().as_str()),
        models_dir: Some(app.get_server_models_dir().to_string()),
    }
}

fn parse_int(s: &str) -> Option<i32> {
    let s = s.trim();
    if s.is_empty() {
        None
    } else {
        s.parse().ok()
    }
}

fn refresh_presets(app: &AppWindow, state: &Rc<RefCell<State>>) {
    let presets = presets::load_all();
    let summaries: Vec<PresetSummary> = presets
        .iter()
        .map(|p| PresetSummary {
            id: p.id.clone().into(),
            model: p.model.clone().into(),
            model_type: p.model_type.clone().into(),
        })
        .collect();

    let model = ModelRc::from(Rc::new(VecModel::from(summaries)));
    app.set_presets(model);

    let prev_sel = app.get_selected_preset_index();
    state.borrow_mut().presets = presets;

    // Try to keep the selection valid.
    let len = state.borrow().presets.len() as i32;
    if prev_sel >= 0 && prev_sel < len {
        // re-emit the form for the same index in case data changed
        if let Some(p) = state.borrow().presets.get(prev_sel as usize) {
            app.set_form(preset_to_form(p));
        }
    } else if len > 0 {
        app.set_selected_preset_index(0);
        if let Some(p) = state.borrow().presets.first() {
            app.set_form(preset_to_form(p));
        }
    } else {
        app.set_selected_preset_index(-1);
        app.set_form(blank_form());
    }
}

fn refresh_mcp(app: &AppWindow) {
    let list: Vec<McpClient> = mcp::detect_all()
        .into_iter()
        .map(|s| McpClient {
            id: s.id.id_str().into(),
            label: s.label.into(),
            config_path: s.config_path.to_string_lossy().into_owned().into(),
            installed: s.installed,
            note: s.note.into(),
        })
        .collect();
    app.set_mcp_clients(ModelRc::from(Rc::new(VecModel::from(list))));
}

fn blank_form() -> PresetForm {
    PresetForm::default()
}

fn preset_to_form(p: &presets::Preset) -> PresetForm {
    PresetForm {
        id: p.id.clone().into(),
        model: p.model.clone().into(),
        model_type: p.model_type.clone().into(),
        vae: p.vae.clone().into(),
        llm: p.llm.clone().into(),
        t5xxl: p.t5xxl.clone().into(),
        clip_l: p.clip_l.clone().into(),
        clip_g: p.clip_g.clone().into(),
        lora_dir: p.lora_dir.clone().into(),
        embd_dir: p.embd_dir.clone().into(),
        weight_type: p.weight_type.clone().into(),
        offload_to_cpu: p.offload_to_cpu.unwrap_or(false),
        mmap: p.mmap.unwrap_or(true),
        fa: p.fa.unwrap_or(false),
        diffusion_fa: p.diffusion_fa.unwrap_or(true),
        clip_on_cpu: p.clip_on_cpu.unwrap_or(false),
        vae_on_cpu: p.vae_on_cpu.unwrap_or(false),
        vae_tiling: p.vae_tiling.unwrap_or(false),
        max_vram: p.max_vram.map(|v| v.to_string()).unwrap_or_default().into(),
        sampler: if p.sampler.is_empty() { "euler_a".into() } else { p.sampler.clone().into() },
        steps: p.steps.unwrap_or(20),
        cfg_scale: p.cfg_scale.map(|v| v.to_string()).unwrap_or_else(|| "7".into()).into(),
        guidance: p.guidance.map(|v| v.to_string()).unwrap_or_default().into(),
        width: p.width.unwrap_or(512),
        height: p.height.unwrap_or(512),
    }
}

fn form_to_preset(f: &PresetForm) -> presets::Preset {
    presets::Preset {
        id: f.id.to_string(),
        model_type: f.model_type.to_string(),
        model: f.model.to_string(),
        vae: f.vae.to_string(),
        llm: f.llm.to_string(),
        t5xxl: f.t5xxl.to_string(),
        clip_l: f.clip_l.to_string(),
        clip_g: f.clip_g.to_string(),
        lora_dir: f.lora_dir.to_string(),
        embd_dir: f.embd_dir.to_string(),
        weight_type: f.weight_type.to_string(),
        offload_to_cpu: Some(f.offload_to_cpu),
        mmap: Some(f.mmap),
        fa: Some(f.fa),
        diffusion_fa: Some(f.diffusion_fa),
        clip_on_cpu: Some(f.clip_on_cpu),
        vae_on_cpu: Some(f.vae_on_cpu),
        vae_tiling: Some(f.vae_tiling),
        max_vram: parse_float_opt(f.max_vram.as_str()),
        sampler: f.sampler.to_string(),
        steps: Some(f.steps).filter(|v| *v > 0),
        cfg_scale: parse_float_opt(f.cfg_scale.as_str()),
        guidance: parse_float_opt(f.guidance.as_str()),
        width: Some(f.width).filter(|v| *v > 0),
        height: Some(f.height).filter(|v| *v > 0),
    }
}

fn parse_float_opt(s: &str) -> Option<f64> {
    let s = s.trim();
    if s.is_empty() {
        None
    } else {
        s.parse().ok()
    }
}

