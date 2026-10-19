# Validation

Host inspected: macOS 27.0 (26A428), Apple Silicon, Xcode macOS SDK; rustup toolchain 1.97.1. Default shell Rust was 1.75.0, so validation uses `/Users/cjus/.cargo/bin/cargo` and the repository toolchain file. No consumer repository was modified and no benchmark was run.

## Automated results

- `cargo test --offline -j 2`: **8 passed** (configuration, no-clobber publication, opt-out, shutdown preconditions, quit waits for terminal state).
- `cargo test --no-default-features --offline -j 2`: **5 passed**.
- `cargo clippy --all-targets --features demo --offline -j 2 -- -D warnings`: **passed**; includes compilation checking of the demo and test targets.
- `cargo fmt --all -- --check`: **passed**.
- `cargo build --features demo --example demo --offline -j 2`: **passed**, executable linked. Apple linker emitted a debug-build warning about a large `__eh_frame` compact-unwind table; it was not a build failure.
- `target/debug/examples/demo --help`: **passed**, executable launched and printed usage without opening a window or capturing anything.
- Native Objective-C bridge: compiled under ARC with `-Wall -Wextra -Werror`.
- `cargo run --no-default-features --example preflight`: returned **false** for existing screen recording permission.

**No playable MP4 has been produced or verified.** Live capture was not attempted because permission is absent. No OS permission prompt was triggered or privacy setting changed. Manually enable the responsible game/launching terminal in System Settings → Privacy & Security → Screen & System Audio Recording and restart it before running the checks below. GUI rendering, A/V playback and isolation, resize behavior, dropped-frame timing, and native disk-error callbacks remain unverified at runtime.

## Live acceptance checklist

A build is not proof of a playable recording. After manually authorizing the responsible game/terminal app:

1. Run without `--record`: verify no capture status or permission request, tone and animation work.
2. Record 15 seconds and press Space. Wait for Finished; play the MP4 in QuickTime. Verify animated square, readable UI clock/status, audible tone, 1920×1080 dimensions, H.264, and duration near elapsed wall time.
3. Repeat and resize the window. Verify fixed output dimensions and preserved aspect ratio.
4. Record while another app plays distinct audio (only if deliberately chosen by the tester). Verify that unrelated audio is absent and the game tone remains. Do not capture that application's window.
5. Record with deliberate low frame rate. Check real-time duration and A/V alignment, including after a long static interval. Cadence may vary; time must not compress.
6. Test Escape and window close during Starting and Recording; verify a finalized file or explicit failure, never a false Saved status.
7. Test denied/revoked permission, existing output, unwritable parent, missing parent, and a controlled full test volume. Check visible errors, unchanged existing files, and recoverable staging.
8. For Deepbore integration later, listen to music, radio and spatial effects together, with headphones and the intended output route. No consumer audio integration is yet verified.

Force termination cannot finalize MP4 reliably. Native application quit shortcuts or consumer `AppExit` must be routed through the recorder lifecycle before production use.
