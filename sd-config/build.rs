fn main() {
    let config = slint_build::CompilerConfiguration::new().with_style("fluent".into());
    slint_build::compile_with_config("ui/app.slint", config).expect("Slint build failed");

    #[cfg(windows)]
    embed_windows_resources();
}

#[cfg(windows)]
fn embed_windows_resources() {
    // Embed the .ico as the EXE's resource icon (visible in Explorer, taskbar,
    // and Alt+Tab). winit picks this up as the default window icon on Windows
    // too, so no extra runtime call is needed.
    let icon = "../resources/stable-diffusion.ico";
    println!("cargo:rerun-if-changed={icon}");
    let mut res = winresource::WindowsResource::new();
    res.set_icon(icon);
    res.set("FileDescription", "stable-diffusion.cpp configurator");
    res.set("ProductName", "stable-diffusion.cpp");
    res.set("OriginalFilename", "sd-config.exe");
    if let Err(e) = res.compile() {
        // Don't break the build if rc.exe is unavailable (e.g. cross-compile);
        // the binary still works, just without an embedded icon.
        println!("cargo:warning=Failed to embed icon resource: {e}");
    }
}
