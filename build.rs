use std::{env, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-changed=native/recorder.m");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let target = env::var("TARGET").unwrap();
    let arch = if target.starts_with("aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    let status = Command::new("xcrun")
        .args([
            "clang",
            "-arch",
            arch,
            "-fobjc-arc",
            "-fblocks",
            "-mmacosx-version-min=15.0",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            "native/recorder.m",
            "-o",
        ])
        .arg(out.join("recorder.o"))
        .status()
        .expect("Xcode command line tools required");
    assert!(
        status.success(),
        "native recorder compilation failed; macOS 15+ SDK required"
    );
    assert!(
        Command::new("ar")
            .arg("crs")
            .arg(out.join("librecorder.a"))
            .arg(out.join("recorder.o"))
            .status()
            .unwrap()
            .success()
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=recorder");
    for framework in [
        "Foundation",
        "AppKit",
        "ScreenCaptureKit",
        "AVFoundation",
        "CoreMedia",
        "CoreGraphics",
    ] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
