// Slint GUI wiring. Loads server.ini + presets.ini + MCP-client state at
// startup, binds every callback declared in ui/app.slint, and writes back
// through the same modules the CLI uses (server_cfg, presets, mcp).

use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

use slint::winit_030::{winit, WinitWindowAccessor};
use slint::{
    ComponentHandle, Image, ModelRc, Rgba8Pixel, SharedPixelBuffer, SharedString, VecModel,
};
#[cfg(windows)]
use winit::platform::windows::WindowExtWindows;

use crate::{mcp, model_scan, net_ifaces, paths, presets, runstate, server_cfg, server_version};

slint::include_modules!();

#[derive(Default)]
struct State {
    presets: Vec<presets::Preset>,
    // One row per LoRA of the currently-edited preset: relative path + weight.
    // Backed by a single VecModel so per-row weight edits update in place
    // (no `for`-rebuild that would steal LineEdit focus mid-typing); the same
    // Rc is handed to Slint as the `lora_entries` property and read back on
    // save by combine_lora_entries.
    lora_model: Rc<VecModel<LoraEntry>>,
}

pub fn run() -> Result<(), Box<dyn std::error::Error>> {
    let app = AppWindow::new()?;
    let state = Rc::new(RefCell::new(State::default()));
    // Wire the LoRA row-model into the UI before the first preset is bound.
    app.set_lora_entries(ModelRc::from(state.borrow().lora_model.clone()));

    // Surface sd-config's own crate version in the About dialog. Tracked
    // independently of the sd-server engine version (which spawn_version_probe
    // fills in); bumped via Cargo.toml's `version`.
    app.set_app_version(SharedString::from(env!("CARGO_PKG_VERSION")));

    set_window_icon(&app);
    load_server_into_ui(&app);
    let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
    refresh_presets(&app, &state, &scan);
    refresh_mcp(&app);
    refresh_run_status(&app);
    refresh_file_options(&app, &scan);
    spawn_version_probe(app.as_weak());

    app.set_presets_path(SharedString::from(
        paths::presets_ini().to_string_lossy().into_owned(),
    ));

    // Click on the status pill → force a re-read (also fired implicitly by
    // the 5s heartbeat below — the manual hook is for the impatient case).
    {
        let app_weak = app.as_weak();
        app.on_refresh_status(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            refresh_run_status(&app);
        });
    }

    // App menu → "Stop Server": terminate the running sd-server, then refresh
    // the footer pill so it flips to "stopped" without waiting for the 5s
    // heartbeat.
    {
        let app_weak = app.as_weak();
        app.on_stop_server(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            match runstate::stop() {
                Ok(true) => set_status(&app, "Stopped sd-server".to_string(), false),
                Ok(false) => set_status(&app, "No running sd-server to stop".to_string(), false),
                Err(e) => set_status(&app, format!("Stop failed: {e}"), true),
            }
            refresh_run_status(&app);
        });
    }

    // Heartbeat: re-probe run\sd-server.state every 5s so the pill flips
    // when sd-server is started or stopped from another window without
    // requiring user action. 5s is well within "feels live" territory for a
    // status indicator and avoids redundant filesystem polling — the user
    // can click the pill (on_refresh_status above) for an immediate update.
    let status_timer = slint::Timer::default();
    {
        let app_weak = app.as_weak();
        status_timer.start(
            slint::TimerMode::Repeated,
            std::time::Duration::from_secs(5),
            move || {
                let Some(app) = app_weak.upgrade() else {
                    return;
                };
                refresh_run_status(&app);
            },
        );
    }

    // ── Server tab callbacks ─────────────────────────────────────────
    {
        let app_weak = app.as_weak();
        app.on_save_server(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let cfg = read_server_from_ui(&app);
            match server_cfg::save(&cfg) {
                Ok(()) => {
                    set_status(
                        &app,
                        format!("Saved {}", paths::server_ini().display()),
                        false,
                    );
                    // ModelsDir may have changed → rebuild the Models-tab
                    // dropdowns so they reflect the new tree.
                    let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
                    refresh_file_options(&app, &scan);
                }
                Err(e) => set_status(&app, format!("Save failed: {e}"), true),
            }
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_revert_server(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            load_server_into_ui(&app);
            // ModelsDir may have changed in memory → rebuild dropdowns so
            // the Models tab matches what's actually on disk again.
            let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
            refresh_file_options(&app, &scan);
            set_status(
                &app,
                format!("Reloaded {}", paths::server_ini().display()),
                false,
            );
        });
    }
    {
        app.on_browse_models_dir(move |current| {
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

    // ── Models tab callbacks ─────────────────────────────────────────
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_select_preset(move |index| {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
            let st = state.borrow();
            if let Some(p) = usize::try_from(index).ok().and_then(|i| st.presets.get(i)) {
                app.set_selected_preset_index(index);
                load_preset_into_form(&app, &scan, &st.lora_model, p);
                // Reanchor each dropdown to the newly loaded form values.
                drop(st);
                refresh_file_options(&app, &scan);
            }
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_save_preset(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
            let lora = combine_lora_entries(&scan, &state.borrow().lora_model);
            let p = form_to_preset(&app.get_form(), lora);
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
                    refresh_presets(&app, &state, &scan);
                    // Reselect the just-saved preset.
                    let st = state.borrow();
                    if let Some(i) = st.presets.iter().position(|x| x.id == p.id) {
                        app.set_selected_preset_index(i as i32);
                    }
                    drop(st);
                    refresh_file_options(&app, &scan);
                }
                Err(e) => set_status(&app, format!("Save failed: {e}"), true),
            }
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_revert_preset(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            // Re-read presets.ini from disk and reload the currently selected
            // entry into the form. If nothing is selected (i.e. a brand-new
            // draft that hasn't been saved), Revert has nothing to revert TO.
            let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
            refresh_presets(&app, &state, &scan);
            let idx = app.get_selected_preset_index();
            let st = state.borrow();
            if let Some(p) = usize::try_from(idx).ok().and_then(|i| st.presets.get(i)) {
                let label = p.id.clone();
                load_preset_into_form(&app, &scan, &st.lora_model, p);
                drop(st);
                refresh_file_options(&app, &scan);
                set_status(&app, format!("Reloaded [{label}] from presets.ini"), false);
            }
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_delete_preset(move |id| {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            if id.is_empty() {
                return;
            }
            match presets::delete(id.as_str()) {
                Ok(()) => {
                    set_status(&app, format!("Deleted [{id}]"), false);
                    let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
                    refresh_presets(&app, &state, &scan);
                    app.set_selected_preset_index(-1);
                    clear_preset_form(&app, &state.borrow().lora_model);
                    refresh_file_options(&app, &scan);
                }
                Err(e) => set_status(&app, format!("Delete failed: {e}"), true),
            }
        });
    }
    // "New…" button. Always shows the embedded modal — it lists the
    // model files scanned from ModelsDir (same source as the editor's
    // Model dropdown). The user picks one + clicks Empty (defaults) or
    // Clone (when a preset is selected: carry over every parameter
    // from that source onto the picked model). No OS file picker is
    // involved — the only path to a preset is a model already in
    // ModelsDir, which keeps the configurator self-contained.
    let pending_clone_base: Rc<RefCell<Option<presets::Preset>>> = Rc::new(RefCell::new(None));
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        let pending_clone_base = pending_clone_base.clone();
        app.on_new_preset(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let selected = {
                let st = state.borrow();
                let idx = app.get_selected_preset_index();
                usize::try_from(idx)
                    .ok()
                    .and_then(|i| st.presets.get(i))
                    .cloned()
            };
            populate_dialog_models(&app);
            match selected {
                None => {
                    *pending_clone_base.borrow_mut() = None;
                    app.set_new_dialog_source_id(SharedString::from(""));
                }
                Some(p) => {
                    app.set_new_dialog_source_id(SharedString::from(p.id.clone()));
                    *pending_clone_base.borrow_mut() = Some(p);
                }
            }
            app.set_show_new_kind_picker(true);
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        let pending_clone_base = pending_clone_base.clone();
        app.on_pick_new_empty(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            *pending_clone_base.borrow_mut() = None;
            let Some(path) = picked_dialog_model_path(&app) else {
                set_status(&app, "Pick a model from the list first.".into(), true);
                return;
            };
            run_new_empty(&app, &state, path);
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_pick_new_clone(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let Some(path) = picked_dialog_model_path(&app) else {
                set_status(&app, "Pick a model from the list first.".into(), true);
                return;
            };
            let Some(base) = pending_clone_base.borrow_mut().take() else {
                set_status(&app, "Clone source no longer available.".into(), true);
                return;
            };
            run_new_clone(&app, &state, base, path);
        });
    }
    {
        let app_weak = app.as_weak();
        let state = state.clone();
        app.on_rename_preset(move |old_id, new_id| {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            match presets::rename(old_id.as_str(), new_id.as_str()) {
                Ok(()) => {
                    set_status(&app, format!("Renamed [{old_id}] → [{new_id}]"), false);
                    // Reload sections from disk; keep the renamed preset selected
                    // by id (its index may have changed if the list was re-sorted).
                    let all = match presets::load_all() {
                        Ok(a) => a,
                        Err(e) => {
                            set_status(&app, format!("Failed to re-read presets.ini: {e}"), true);
                            return;
                        }
                    };
                    let summaries: Vec<PresetSummary> = all
                        .iter()
                        .map(|q| PresetSummary {
                            id: q.id.clone().into(),
                            model: q.model.clone().into(),
                            model_type: q.model_type.clone().into(),
                        })
                        .collect();
                    app.set_presets(ModelRc::from(Rc::new(VecModel::from(summaries))));
                    let new_idx = all
                        .iter()
                        .position(|q| q.id == new_id.as_str())
                        .map(|i| i as i32)
                        .unwrap_or(-1);
                    let renamed = all.iter().find(|q| q.id == new_id.as_str()).cloned();
                    state.borrow_mut().presets = all;
                    app.set_selected_preset_index(new_idx);
                    let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
                    if let Some(p) = renamed {
                        load_preset_into_form(&app, &scan, &state.borrow().lora_model, &p);
                    }
                    refresh_file_options(&app, &scan);
                }
                Err(e) => set_status(&app, format!("Rename failed: {e}"), true),
            }
        });
    }
    {
        app.on_browse_dir(move |_field, current| {
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
    {
        let state = state.clone();
        app.on_add_lora(move |picked| {
            use slint::Model;
            let picked = picked.trim().to_string();
            if picked.is_empty() {
                return;
            }
            let model = state.borrow().lora_model.clone();
            // sd-server resolves all of a preset's LoRAs against ONE directory
            // (run-server.ps1 derives it from the first entry's parent), and
            // sub-folders ARE different directories — so a pick from another
            // sub-folder won't load at render time. Warn (cancellable) before
            // appending one whose sub-folder differs from the LAST row's.
            // (rfd MessageDialog is safe — the comctl6 manifest is embedded by
            // build.rs; see memory sd-config-manifest-comctl6.)
            let n = model.row_count();
            if n > 0 {
                if let Some(last) = model.row_data(n - 1) {
                    let prev = lora_rel_parent(last.path.as_str());
                    let pick = lora_rel_parent(&picked);
                    if !prev.eq_ignore_ascii_case(&pick) {
                        let prev_disp = if prev.is_empty() { "loras root".to_string() } else { prev };
                        let ok = rfd::MessageDialog::new()
                            .set_level(rfd::MessageLevel::Warning)
                            .set_title("LoRA is in a different folder")
                            .set_description(format!(
                                "All of a preset's LoRAs must live in one folder — sd-server resolves \
                                 them against the first entry's folder ({}), so this file ({}) will not \
                                 load at render time.\n\nAdd it anyway?",
                                prev_disp, picked,
                            ))
                            .set_buttons(rfd::MessageButtons::OkCancel)
                            .show();
                        if ok != rfd::MessageDialogResult::Ok {
                            return;
                        }
                    }
                }
            }
            // Append a new row; weight blank = default 1.0 (user fills it in).
            model.push(LoraEntry {
                path: SharedString::from(picked),
                weight: SharedString::new(),
            });
        });
    }
    {
        let state = state.clone();
        app.on_remove_lora(move |index| {
            use slint::Model;
            let model = state.borrow().lora_model.clone();
            if let Ok(i) = usize::try_from(index) {
                if i < model.row_count() {
                    model.remove(i);
                }
            }
        });
    }

    // ── MCP tab callbacks ─────────────────────────────────────────────
    {
        let app_weak = app.as_weak();
        app.on_mcp_install(move |id| {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let Some(cid) = mcp::ClientId::from_str(id.as_str()) else {
                return;
            };
            match mcp::install(cid) {
                Ok(()) => set_status(
                    &app,
                    format!("Installed: {}", cid.config_path().display()),
                    false,
                ),
                Err(e) => set_status(&app, format!("Install failed: {e:#}"), true),
            }
            refresh_mcp(&app);
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_mcp_uninstall(move |id| {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            let Some(cid) = mcp::ClientId::from_str(id.as_str()) else {
                return;
            };
            match mcp::uninstall(cid) {
                Ok(()) => set_status(
                    &app,
                    format!("Removed: {}", cid.config_path().display()),
                    false,
                ),
                Err(e) => set_status(&app, format!("Uninstall failed: {e:#}"), true),
            }
            refresh_mcp(&app);
        });
    }
    {
        let app_weak = app.as_weak();
        app.on_mcp_refresh(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
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
        let Some(app) = app_weak.upgrade() else {
            return;
        };
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

/// Sub-folder of a single relative `lora` entry (after stripping any
/// `:<mult>`), or "" when the entry sits at the loras root. Used by the
/// add-LoRA warning to spot a pick from a different sub-folder than the
/// existing entries — they must all share one directory.
fn lora_rel_parent(spec: &str) -> String {
    let (path, _) = model_scan::split_lora_multiplier(spec);
    std::path::Path::new(path)
        .parent()
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Push the scanned model list (Category::Model under ModelsDir) into
/// the dialog's model picker. Reset the selection — the dialog re-opens
/// "blank" each time, the user must pick a row before Empty/Clone go
/// active. No selection sentinel needed; -1 means "not chosen yet".
fn populate_dialog_models(app: &AppWindow) {
    let models_dir = app.get_server_models_dir().to_string();
    let scanned = model_scan::list(&models_dir, model_scan::Category::Model);
    let labels: Vec<SharedString> = scanned
        .iter()
        .map(|f| SharedString::from(f.label.clone()))
        .collect();
    let values: Vec<SharedString> = scanned
        .iter()
        .map(|f| SharedString::from(f.path.clone()))
        .collect();
    app.set_dialog_model_labels(ModelRc::from(Rc::new(VecModel::from(labels))));
    app.set_dialog_model_values(ModelRc::from(Rc::new(VecModel::from(values))));
    app.set_dialog_model_index(-1);
}

/// Look up the path of the currently-selected row in the dialog's model
/// picker. None when nothing is selected (`dialog_model_index < 0`) or
/// the index is out-of-range (shouldn't happen but cheap to guard).
fn picked_dialog_model_path(app: &AppWindow) -> Option<PathBuf> {
    use slint::Model;
    let idx = app.get_dialog_model_index();
    if idx < 0 {
        return None;
    }
    let values = app.get_dialog_model_values();
    let i = usize::try_from(idx).ok()?;
    if i >= values.row_count() {
        return None;
    }
    let s = values.row_data(i)?;
    Some(PathBuf::from(s.to_string()))
}

/// Empty-template flow: build a fresh Preset with defaults around the
/// picked model path, write it to presets.ini, select it in the list.
fn run_new_empty(app: &AppWindow, state: &Rc<RefCell<State>>, path: PathBuf) {
    let id = presets::make_id(&path.to_string_lossy());
    let p = presets::Preset::new_default(
        id.clone(),
        path.to_string_lossy().into_owned(),
        "standalone".into(),
    );
    commit_new_preset(
        app,
        state,
        p,
        format!("Added [{id}] — tweak parameters and Save."),
    );
}

/// Clone flow: keep every field from `base` (vae, t5xxl, clip_l/g,
/// sampler, steps, cfg, …) but swap the model path to the picked one.
/// The new preset's id matches the picked model's stem — same
/// convention as the Empty flow, so the user doesn't have to invent a
/// name. Persists immediately to presets.ini.
fn run_new_clone(
    app: &AppWindow,
    state: &Rc<RefCell<State>>,
    base: presets::Preset,
    path: PathBuf,
) {
    let path_str = path.to_string_lossy().into_owned();
    let id = presets::make_id(&path_str);
    let cloned = presets::Preset {
        id: id.clone(),
        model: path_str,
        ..base.clone()
    };
    commit_new_preset(
        app,
        state,
        cloned,
        format!(
            "Cloned [{}] → [{id}] (new model, same parameters) — saved.",
            base.id
        ),
    );
}

/// Shared tail of both New flows: write the preset to presets.ini, reload
/// the section list from disk, select the new row, and bind it into the
/// editor form. Deliberately bypasses [`refresh_presets`] so the form is
/// only written once — refresh_presets's prev-selection fallback would
/// otherwise re-bind it to the source preset (because the user clicked
/// "New…" while a different preset was selected), and the picked model
/// would silently revert.
fn commit_new_preset(
    app: &AppWindow,
    state: &Rc<RefCell<State>>,
    p: presets::Preset,
    success_status: String,
) {
    match presets::save(&p) {
        Ok(()) => {
            let all = match presets::load_all() {
                Ok(a) => a,
                Err(e) => {
                    set_status(
                        app,
                        format!("Saved, but failed to re-read presets.ini: {e}"),
                        true,
                    );
                    return;
                }
            };
            let summaries: Vec<PresetSummary> = all
                .iter()
                .map(|q| PresetSummary {
                    id: q.id.clone().into(),
                    model: q.model.clone().into(),
                    model_type: q.model_type.clone().into(),
                })
                .collect();
            app.set_presets(ModelRc::from(Rc::new(VecModel::from(summaries))));
            let new_idx = all
                .iter()
                .position(|q| q.id == p.id)
                .map(|i| i as i32)
                .unwrap_or(-1);
            state.borrow_mut().presets = all;
            app.set_selected_preset_index(new_idx);
            let scan = model_scan::LoraScan::new(app.get_server_models_dir().as_str());
            load_preset_into_form(app, &scan, &state.borrow().lora_model, &p);
            refresh_file_options(app, &scan);
            set_status(app, success_status, false);
        }
        Err(e) => set_status(app, format!("Save failed: {e}"), true),
    }
}

fn set_status(app: &AppWindow, text: String, is_error: bool) {
    app.set_status_text(SharedString::from(text));
    app.set_status_is_error(is_error);
}

fn load_server_into_ui(app: &AppWindow) {
    // A read failure (locked file, mangled encoding) falls back to defaults
    // in the form, but is surfaced in the status bar — saving over a file we
    // couldn't read would otherwise silently discard its contents.
    let cfg = match server_cfg::load() {
        Ok(c) => c,
        Err(e) => {
            set_status(app, format!("Failed to read server.ini: {e}"), true);
            server_cfg::ServerConfig::default()
        }
    };
    app.set_server_port(SharedString::from(
        cfg.port
            .map(|v| v.to_string())
            .unwrap_or_else(|| "1234".into()),
    ));
    let hostname = cfg.hostname.unwrap_or_else(|| "localhost".into());
    populate_bind_options(app, &hostname);
    app.set_server_hostname(SharedString::from(hostname));
    app.set_server_threads(SharedString::from(
        cfg.threads.map(|v| v.to_string()).unwrap_or_default(),
    ));
    app.set_server_models_dir(SharedString::from(
        cfg.models_dir
            .unwrap_or_else(server_cfg::default_models_dir),
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

fn refresh_presets(app: &AppWindow, state: &Rc<RefCell<State>>, scan: &model_scan::LoraScan) {
    let presets = match presets::load_all() {
        Ok(p) => p,
        Err(e) => {
            // Show the failure instead of a silently-empty list: an empty
            // list invites the user to re-create presets, and the next save
            // would then clobber a file that was merely unreadable.
            set_status(app, format!("Failed to read presets.ini: {e}"), true);
            return;
        }
    };
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

    // Try to keep the selection valid. Take one shared borrow after the
    // mutable borrow above has dropped — previously this function took
    // three separate `state.borrow()` calls in a row, which read fine but
    // was a future foot-gun (any of them could collide with a re-entrant
    // borrow_mut sneaking in via a Slint callback).
    let st = state.borrow();
    let len = st.presets.len() as i32;
    if prev_sel >= 0 && prev_sel < len {
        if let Some(p) = st.presets.get(prev_sel as usize) {
            load_preset_into_form(app, scan, &st.lora_model, p);
        }
    } else if len > 0 {
        app.set_selected_preset_index(0);
        if let Some(p) = st.presets.first() {
            load_preset_into_form(app, scan, &st.lora_model, p);
        }
    } else {
        app.set_selected_preset_index(-1);
        clear_preset_form(app, &st.lora_model);
    }
}

/// Rebuild the six Models-tab dropdowns (Model / VAE / LLM / T5-XXL /
/// CLIP-L / CLIP-G) plus the "+ Add a LoRA…" picker from the current
/// `server_models_dir` setting and the current `form` values. Cheap (a few
/// directory reads) — safe to call on every preset switch and every save.
///
/// `scan` is the per-event LoRA scan (see [`model_scan::LoraScan`]); its
/// `scanned` list drives the add-LoRA dropdown directly so the (recursive)
/// loras walk is shared with the caller's preset-load, not repeated here.
///
/// CLIP-L and CLIP-G share an identical `scan_relatives` list in
/// `model_scan::Category` (the user picks which file is L vs G out of the
/// same `clips\` directory), so we scan once and clone the result into both
/// dropdowns rather than walking the filesystem twice.
fn refresh_file_options(app: &AppWindow, scan: &model_scan::LoraScan) {
    let models_dir = app.get_server_models_dir().to_string();
    let form = app.get_form();

    // Uncond diffusion model (Ideogram4) is the same kind of file as the
    // conditional one and resolves to the identical directory list, so scan
    // Category::Model once and clone the result into both dropdowns.
    let model_scan_result = model_scan::list(&models_dir, model_scan::Category::Model);
    let uncond_scan_result = model_scan_result.clone();
    let vae_scan_result = model_scan::list(&models_dir, model_scan::Category::Vae);
    let llm_scan_result = model_scan::list(&models_dir, model_scan::Category::Llm);
    let t5xxl_scan_result = model_scan::list(&models_dir, model_scan::Category::T5xxl);
    // ClipL and ClipG resolve to identical directories — scan once.
    let clip_scan_result = model_scan::list(&models_dir, model_scan::Category::ClipL);

    apply_scanned(
        app,
        model_scan::Category::Model,
        model_scan_result,
        form.model.as_str(),
        |app, lbl, val, idx| {
            app.set_model_labels(lbl);
            app.set_model_values(val);
            app.set_model_index(idx);
        },
    );
    apply_scanned(
        app,
        model_scan::Category::Model,
        uncond_scan_result,
        form.uncond_diffusion_model.as_str(),
        |app, lbl, val, idx| {
            app.set_uncond_dm_labels(lbl);
            app.set_uncond_dm_values(val);
            app.set_uncond_dm_index(idx);
        },
    );
    apply_scanned(
        app,
        model_scan::Category::Vae,
        vae_scan_result,
        form.vae.as_str(),
        |app, lbl, val, idx| {
            app.set_vae_labels(lbl);
            app.set_vae_values(val);
            app.set_vae_index(idx);
        },
    );
    apply_scanned(
        app,
        model_scan::Category::Llm,
        llm_scan_result,
        form.llm.as_str(),
        |app, lbl, val, idx| {
            app.set_llm_labels(lbl);
            app.set_llm_values(val);
            app.set_llm_index(idx);
        },
    );
    apply_scanned(
        app,
        model_scan::Category::T5xxl,
        t5xxl_scan_result,
        form.t5xxl.as_str(),
        |app, lbl, val, idx| {
            app.set_t5xxl_labels(lbl);
            app.set_t5xxl_values(val);
            app.set_t5xxl_index(idx);
        },
    );
    apply_scanned(
        app,
        model_scan::Category::ClipL,
        clip_scan_result.clone(),
        form.clip_l.as_str(),
        |app, lbl, val, idx| {
            app.set_clip_l_labels(lbl);
            app.set_clip_l_values(val);
            app.set_clip_l_index(idx);
        },
    );
    apply_scanned(
        app,
        model_scan::Category::ClipG,
        clip_scan_result,
        form.clip_g.as_str(),
        |app, lbl, val, idx| {
            app.set_clip_g_labels(lbl);
            app.set_clip_g_values(val);
            app.set_clip_g_index(idx);
        },
    );

    // LoRA "Add" dropdown. Unlike the model combos this is an ACTION picker —
    // it appends a relative path to the comma-separated `lora` field rather
    // than tracking a current selection — so it carries labels only (no
    // values / index). Row 0 is a sentinel so re-picking the same file still
    // fires `selected`; the rest are paths relative to the loras root,
    // including sub-folders. Reuses the shared `scan` so the recursive loras
    // walk doesn't repeat the one already done for the preset-load.
    let mut lora_labels: Vec<SharedString> = Vec::with_capacity(scan.scanned.len() + 1);
    lora_labels.push(SharedString::from("+ Add a LoRA…"));
    lora_labels.extend(
        scan.scanned
            .iter()
            .map(|o| SharedString::from(o.label.clone())),
    );
    app.set_lora_labels(ModelRc::from(Rc::new(VecModel::from(lora_labels))));
}

fn apply_scanned(
    app: &AppWindow,
    category: model_scan::Category,
    scanned: Vec<model_scan::FileOption>,
    current: &str,
    apply: impl FnOnce(&AppWindow, ModelRc<SharedString>, ModelRc<SharedString>, i32),
) {
    let (labels, values, idx) = model_scan::build_options(category, scanned, current);
    let labels_model = ModelRc::from(Rc::new(VecModel::from(
        labels
            .into_iter()
            .map(SharedString::from)
            .collect::<Vec<_>>(),
    )));
    let values_model = ModelRc::from(Rc::new(VecModel::from(
        values
            .into_iter()
            .map(SharedString::from)
            .collect::<Vec<_>>(),
    )));
    apply(app, labels_model, values_model, idx);
}

/// Spawn `sd-server.exe --version` on a background thread and push the
/// parsed version string into `server_version`. Backgrounded because a
/// cold subprocess launch can stall the UI for a few hundred ms on
/// Windows (AV scan of the EXE, etc.), and the header doesn't need the
/// value during the first paint.
fn spawn_version_probe(app_weak: slint::Weak<AppWindow>) {
    std::thread::spawn(move || {
        let version = server_version::probe();
        slint::invoke_from_event_loop(move || {
            let Some(app) = app_weak.upgrade() else {
                return;
            };
            app.set_server_version(SharedString::from(version.unwrap_or_default()));
        })
        .ok();
    });
}

/// Probe `run\sd-server.state` and push the result into the footer pill
/// (green dot + "started: <preset/model>" when alive, neutral "stopped"
/// otherwise). Host/port are intentionally omitted — they live in the Server
/// tab; the pill is a compact running/stopped indicator.
fn refresh_run_status(app: &AppWindow) {
    match runstate::load() {
        Some(s) => {
            let text = if s.preset.is_empty() {
                "started".to_string()
            } else {
                format!("started: {}", s.preset)
            };
            app.set_server_running(true);
            app.set_server_status_text(SharedString::from(text));
        }
        None => {
            app.set_server_running(false);
            app.set_server_status_text(SharedString::from("stopped"));
        }
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

/// Bind a preset into the editor: the scalar fields via `preset_to_form` and
/// the LoRA rows via `set_lora_entries_from`. `scan` is the per-event LoRA scan
/// (see [`model_scan::LoraScan`]) shared with the caller's `refresh_file_options`
/// so the loras tree is walked once per UI event, not twice.
fn load_preset_into_form(
    app: &AppWindow,
    scan: &model_scan::LoraScan,
    lora_model: &VecModel<LoraEntry>,
    p: &presets::Preset,
) {
    app.set_form(preset_to_form(p));
    set_lora_entries_from(scan, lora_model, &p.lora);
}

/// Reset the editor to the no-preset-selected state: default scalar fields and
/// an empty LoRA row-model.
fn clear_preset_form(app: &AppWindow, lora_model: &VecModel<LoraEntry>) {
    app.set_form(blank_form());
    lora_model.set_vec(Vec::new());
}

/// Replace the LoRA row-model from a stored FULL `lora` value (`path:mult, …`).
/// Splits it into relative paths + per-LoRA weights via lora_split_display and
/// fills one `LoraEntry` row per LoRA. Pass an empty `full_lora` to clear.
/// `scan` is the per-event LoRA scan (see [`model_scan::LoraScan`]).
fn set_lora_entries_from(
    scan: &model_scan::LoraScan,
    model: &VecModel<LoraEntry>,
    full_lora: &str,
) {
    let (paths_csv, weights_csv) = model_scan::lora_split_display(scan, full_lora);
    let paths: Vec<&str> = if paths_csv.trim().is_empty() {
        Vec::new()
    } else {
        paths_csv
            .split(',')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect()
    };
    let weights: Vec<&str> = weights_csv.split(',').map(|s| s.trim()).collect();
    let entries: Vec<LoraEntry> = paths
        .iter()
        .enumerate()
        .map(|(i, p)| LoraEntry {
            path: SharedString::from(*p),
            weight: SharedString::from(weights.get(i).copied().unwrap_or("")),
        })
        .collect();
    model.set_vec(entries);
}

/// Read the LoRA row-model back into a stored FULL `lora` value. Inverse of
/// set_lora_entries_from: recombines the rows' relative paths + weights via
/// lora_combine_full (blank weight → default 1.0). `scan` is the per-event LoRA
/// scan (see [`model_scan::LoraScan`]).
fn combine_lora_entries(scan: &model_scan::LoraScan, model: &VecModel<LoraEntry>) -> String {
    use slint::Model;
    let n = model.row_count();
    let mut paths: Vec<String> = Vec::with_capacity(n);
    let mut weights: Vec<String> = Vec::with_capacity(n);
    for i in 0..n {
        if let Some(e) = model.row_data(i) {
            paths.push(e.path.to_string());
            weights.push(e.weight.to_string());
        }
    }
    let paths_csv = paths.join(", ");
    let weights_csv = if weights.iter().all(|w| w.trim().is_empty()) {
        String::new()
    } else {
        weights.join(", ")
    };
    model_scan::lora_combine_full(scan, &paths_csv, &weights_csv)
}

fn blank_form() -> PresetForm {
    PresetForm::default()
}

fn preset_to_form(p: &presets::Preset) -> PresetForm {
    // LoRAs are NOT carried in the form — they live in the `lora_entries`
    // row-model (see set_lora_entries_from / combine_lora_entries), edited as
    // one row per LoRA with its weight beside it.
    PresetForm {
        id: p.id.clone().into(),
        model: p.model.clone().into(),
        model_type: p.model_type.clone().into(),
        uncond_diffusion_model: p.uncond_diffusion_model.clone().into(),
        vae: p.vae.clone().into(),
        llm: p.llm.clone().into(),
        t5xxl: p.t5xxl.clone().into(),
        clip_l: p.clip_l.clone().into(),
        clip_g: p.clip_g.clone().into(),
        legacy_lora_dir: p.legacy_lora_dir.clone().into(),
        lora_apply_mode: p.lora_apply_mode.clone().into(),
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
        sampler: if p.sampler.is_empty() {
            "euler".into()
        } else {
            p.sampler.clone().into()
        },
        flow_shift: p
            .flow_shift
            .map(|v| v.to_string())
            .unwrap_or_default()
            .into(),
        steps: p.steps.unwrap_or(20),
        cfg_scale: p
            .cfg_scale
            .map(|v| v.to_string())
            .unwrap_or_else(|| "7".into())
            .into(),
        guidance: p.guidance.map(|v| v.to_string()).unwrap_or_default().into(),
        width: p.width.unwrap_or(512),
        height: p.height.unwrap_or(512),
    }
}

fn form_to_preset(f: &PresetForm, lora: String) -> presets::Preset {
    presets::Preset {
        id: f.id.to_string(),
        model_type: f.model_type.to_string(),
        model: f.model.to_string(),
        uncond_diffusion_model: f.uncond_diffusion_model.to_string(),
        vae: f.vae.to_string(),
        llm: f.llm.to_string(),
        t5xxl: f.t5xxl.to_string(),
        clip_l: f.clip_l.to_string(),
        clip_g: f.clip_g.to_string(),
        // Combined from the `lora_entries` row-model by the caller (see
        // combine_lora_entries) — the form no longer carries LoRA paths.
        lora,
        legacy_lora_dir: f.legacy_lora_dir.to_string(),
        lora_apply_mode: f.lora_apply_mode.to_string(),
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
        flow_shift: parse_float_opt(f.flow_shift.as_str()),
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
