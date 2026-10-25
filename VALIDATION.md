# Validation

See [docs/PRD.md](docs/PRD.md) for acceptance requirements and [status.md](status.md) for current progress and next steps. Operational permission instructions are maintained in [README](README.md#permission).

Host inspected: macOS 27.0 (26A428), Apple Silicon, Xcode macOS SDK; rustup toolchain 1.97.1. Default shell Rust was 1.75.0, so validation uses `/Users/cjus/.cargo/bin/cargo` and the repository toolchain file. No consumer repository was modified and no benchmark was run.

## Automated results

- `cargo test --offline -j 2`: **9 passed** (configuration, no-clobber publication, opt-out, shutdown preconditions, quit waits for terminal state).
- 2026-10-24 (#3, window shape): the native harness tests the video's size: a 16:9 window fills 1920×1080, Solrac's 1440×932 gives 1668×1080, wider and taller windows fit the limiting side exactly, the other side is rounded then made even, and an unmeasurable or too-thin window keeps the configured size.
- 2026-10-24, live, before #3 (Solrac, cjus/chessgui#175, macOS 27.0, M1 Max): **three playable MP4s.** Each was H.264 at 1920×1080 with AAC 48 kHz stereo audio, averaging about 29.2–29.5 fps, with the longest gap between frames 0.18–0.34 s. Their durations were 42.5, 29.2 and 22.7 s, for quits 45.1, 30.1 and 25.1 s after launch; capture starts once the window is up, so the title screen is included. Quitting by macOS's quit request (the ⌘Q path, `NSRunningApplication.terminate`) and by SIGINT (Ctrl+C) each went Stopping → Finished in under 0.1 s, published the file with no staging left, and quit. The pieces' sounds were in the audio (peak about 0.61). Found: a window that isn't 16:9 left a black band down the right, now fixed (#3). Also, a game started as a background job of a non-interactive shell inherits SIGINT ignored, so `ctrlc` reports "already registered" and Ctrl+C can't save the recording; a terminal's foreground job, or `set -m`, is fine.
- 2026-10-24, commit `24863c4` (#1, quit routes): `cargo test` **13 passed**, adding Ctrl+C turning into `quit()`, no recording started by a quit before the start, frames asked for while starting or stopping, and the check that Bevy's own Ctrl+C handler is disabled. `cargo test --no-default-features` 6 passed; Clippy (all targets, with demo, and without default features) and formatting passed; the demo built and printed `--help`. The native harness now also runs AppKit's real `-[NSApplication terminate:]` against a fake unfinished session: it returns with the quit request noted, and `applicationShouldTerminate:` answers `NSTerminateNow` once the session is finished or failed. Run without the guard installed, the harness fails ("terminate: went through"), so it does test the guard.
- `cargo test --no-default-features --offline -j 2`: **6 passed**.
- `cargo clippy --all-targets --features demo --offline -j 2 -- -D warnings`: **passed**; includes compilation checking of the demo and test targets.
- `cargo fmt --all -- --check`: **passed**.
- `cargo build --features demo --example demo --offline -j 2`: **passed**, executable linked. Apple linker emitted a debug-build warning about a large `__eh_frame` compact-unwind table; it was not a build failure.
- `target/debug/examples/demo --help`: **passed**, executable launched and printed usage without opening a window or capturing anything.
- Native Objective-C bridge: compiled under ARC with `-Wall -Wextra -Werror`.
- `cargo run --no-default-features --example preflight`: returned **false** for existing screen recording permission.

**No playable MP4 has been produced or verified.** Live capture was not attempted because permission is absent. No OS permission prompt was triggered or privacy setting changed. Use the exact bundled-app permission and launch instructions in README before running the checks below. The original unbundled preflight cannot determine the privacy identity of a different launcher. GUI rendering, A/V playback and isolation, resize behavior, dropped-frame timing, and native disk-error callbacks remain unverified at runtime.

## Live acceptance checklist

A build is not proof of a playable recording. After manually authorizing the specific demo bundle described in [README](README.md#permission):

1. Run without `--record`: verify no capture status or permission request, tone and animation work.
2. Record 15 seconds and press Space. Wait for Finished; play the MP4 in QuickTime. Verify animated square, readable UI clock/status, audible tone, 1920×1080 dimensions, H.264, and duration near elapsed wall time.
3. Repeat and resize the window. Verify fixed output dimensions and preserved aspect ratio.
4. Record while another app plays distinct audio (only if deliberately chosen by the tester). Verify that unrelated audio is absent and the game tone remains. Do not capture that application's window.
5. Record with deliberate low frame rate. Check real-time duration and A/V alignment, including after a long static interval. Cadence may vary; time must not compress.
6. Test Escape and window close during Starting and Recording; verify a finalized file or explicit failure, never a false Saved status.
6a. Repeat with **⌘Q**, the **Dock's Quit** and **Ctrl+C** in the launching terminal (#1): each must show Finalizing, then quit with a playable MP4. A second Ctrl+C exits at once (no MP4 is promised). ⌘Q after the recording has finished or failed quits at once.
7. Test denied/revoked permission, existing output, unwritable parent, missing parent, and a controlled full test volume. Check visible errors, unchanged existing files, and recoverable staging.
8. For Deepbore integration later, listen to music, radio and spatial effects together, with headphones and the intended output route. No consumer audio integration is yet verified.

Force termination cannot finalize MP4 reliably. ⌘Q, the Dock's Quit, logout and Ctrl+C are routed through the recorder lifecycle by the plugin (#1); a consumer's own `AppExit` must still go through `Recorder::quit()`.

## Focused review follow-up

An independent reviewer checked native window/PID filtering, application audio policy, microphone exclusion, fixed resize dimensions, Bevy APIs and shutdown lifetimes. Two lifecycle bugs were fixed: late native startup after Rust timeout/drop, and premature timeout classification before observing native completion. Native terminal callbacks are now idempotent; pending discovery is cancelled and an in-flight/late start is stopped on abort. Rust reads native progress before applying deadlines.

Regression validation adds a no-capture native lifecycle harness (abort before discovery, late callbacks, abort while starting, idempotence, immutable completion) and Rust deadline/progress tests. The local `BevyRecorderDemo.app` bundle has a validated plist, ad-hoc signature and bundled audio asset. It has not been launched via LaunchServices or used to request permission. No capture or permission API is called by the native harness.
