# Icon wiring

The same `resources/stable-diffusion.ico` is plumbed through **two
independent paths**. Both are load-bearing in different surfaces.

## Path 1: EXE resource fork (Explorer, Start Menu, taskbar pinning)

`build.rs` uses the `winresource` crate to embed
`resources/stable-diffusion.ico` into the compiled EXE's Win32 resource fork.
Explorer and the Start Menu read this directly.

**Caveat — icon cache.** Windows aggressively caches icons per-EXE path. If a
build was shipped without the resource and a later build adds it, Explorer
will keep showing the old (or default) icon until the cache is invalidated.
Workarounds:

- Kill `explorer.exe` and let it restart (`taskkill /F /IM explorer.exe`),
- Reboot, or
- Move the EXE to a new path.

## Path 2: Live window icon (title bar, Alt+Tab, taskbar of the running process)

The .ico is also `include_bytes!`'d into the binary and decoded at runtime by
`gui::set_window_icon`, which feeds the result to the underlying winit window
via `slint::winit_030::WinitWindowAccessor::with_winit_window`.

### Why two frame sizes

`gui::set_window_icon` decodes **two** frames out of the .ico, picking the
entry whose width is closest to the target:

- `~32×32` for `ICON_SMALL` — the title bar / system menu / small Alt+Tab.
- `~256×256` for `ICON_BIG` — the taskbar / large Alt+Tab thumbnail.

On Windows winit 0.30:

- `Window::set_window_icon(...)` routes to `WM_SETICON ICON_SMALL`.
- The platform extension `WindowExtWindows::set_taskbar_icon(...)` routes to
  `WM_SETICON ICON_BIG`.

Passing the same 256×256 RGBA to both makes the title bar a blurry /
unrenderable mush after Windows downsamples it to ~16 px. Selecting
per-slot sizes is what actually makes the title-bar icon appear sharp.

### Why a deferred Timer

`WinitWindowAccessor::with_winit_window` only works once the underlying winit
window exists, which doesn't happen until `app.run()` starts the event loop.
The icon-setting closure is deferred via
`slint::Timer::single_shot(50ms, ...)` so it fires on the first event-loop
iteration after `show()`.

### About the Slint `Window.icon` binding

`app.slint` declares an `in property <image>` mirror on `AppWindow.icon` and
the Rust side keeps it in sync. This is for forward compatibility — as of
Slint 1.16 the `WindowProperties` surface that backends consume does **not**
include `icon`, so the Slint property alone has no visible effect today. The
winit-accessor path is the load-bearing one. If a future Slint release adds
OS-window propagation through `Window.icon`, the existing binding will start
contributing automatically.

### Required Slint feature

The winit accessor requires the `unstable-winit-030` feature on the `slint`
crate. It's enabled in `Cargo.toml`.
