# bevy-game-recorder

An opt-in Rust/Bevy recorder for **macOS 15+**, Bevy **0.20**, and Rust **1.97.1**. Records one game window, its composed UI, and that application's audio into a local H.264 MP4. No uploading, microphone capture, display-wide capture, or FFmpeg installation.

This is a first implementation, not a claim of validated support for a consumer game. See [validation](VALIDATION.md) for exactly what has been tested.

## Run the demo

Requires Xcode command-line tools with a macOS 15+ SDK. No runtime encoder executable is needed. Use the rustup-managed Cargo if your PATH contains an older Homebrew Rust.

```sh
cargo run --features demo --example demo
cargo run --features demo --example demo -- --record gameplay.mp4
```

Without `--record`, no capture or permission check occurs. The demo animates a square, renders a UI clock/status indicator, and plays a quiet looping 440 Hz tone. **Space** stops and saves; **Escape** or window close finalizes then quits. Keep the event loop running while “Stopping” is displayed. The title bar also shows recorder state. The demo's generated tone is included in `assets/tone.wav` and needs no download.

Default output: 1920×1080, at most 30 fps, SDR H.264 MP4, stereo 48 kHz application audio. Apple controls bitrate and audio codec selection. Output dimensions stay fixed across window resizing, with aspect ratio preserved. Recording is timestamped media with potentially variable frame cadence, not guaranteed constant-frame-rate output. A delayed frame does not remove elapsed time by advancing a raw frame counter.

## Permission

```sh
cargo run --no-default-features --example preflight
```

This only checks existing permission. The library never calls the permission-request API or changes settings. If false, manually enable the game or its launching terminal in **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and restart that application/terminal. For a distributed game, use a signed app bundle with a stable identity. The responsible application shown by macOS can differ between terminal and bundled launches. If it does not appear, use the system panel's add control to select the app. Permission belongs to the user; it is not granted by a successful build.

## Integrate

```toml
[dependencies]
bevy-game-recorder = { path = "../bevy-game-recorder" }
```

```rust,no_run
use bevy::{prelude::*, window::ExitCondition};
use bevy_game_recorder::{RecorderPlugin, RecordingConfig};

let requested_output: Option<String> = None; // Populate from your own CLI parser.
let config = requested_output.map(|path| RecordingConfig::new(path, "My Game"));
App::new()
    .add_plugins(DefaultPlugins.set(WindowPlugin {
        primary_window: Some(Window { title: "My Game".into(), ..default() }),
        close_when_requested: false,
        exit_condition: ExitCondition::DontExit,
        ..default()
    }))
    .add_plugins(RecorderPlugin(config))
    .run();
```

The plugin expects a primary window with an exact, unique native title at startup, waits three update frames for creation, and verifies the selected native window belongs to the current process. Failure to resolve it fails closed. It does not fall back to a display or another application's window. Install after `DefaultPlugins`. Avoid changing the primary title independently; the recorder appends its visible status. Add an in-game indicator based on `Recorder.state` if the title bar is hidden (see demo).

Use `ResMut<Recorder>::stop()` to save without quitting, or `quit()` to save and quit. Route **all** game quit/menu actions through `quit()`. Direct `AppExit`, `process::exit`, panic/abort, force quit and signals bypass graceful finalization. Window close is handled by the plugin; automatic window destruction and automatic exit must be disabled as above. Other windows' close handling remains the consumer's responsibility.

`Recorder.state` exposes Starting, Recording, Stopping, Finished or Failed(error); None means disabled. Check failures and surface them to players. Stopping is nonblocking. Start/finalization times out after 30 seconds of polling, reports failure, and preserves partial output rather than claiming success. There is one recording session per process in this first version; restart to record again.

For custom integration without Bevy, disable default features and use `RecordingSession` on the macOS main thread. Continue pumping the native event loop and calling `poll()` until terminal. `Drop` requests stop but cannot promise finalization after the event loop exits.

## Backend and audio tradeoffs

A small Objective-C ARC bridge uses `SCContentFilter(desktopIndependentWindow:)`, `SCStream`, and `SCRecordingOutput` (introduced in macOS 15). This includes final window compositing regardless of Bevy cameras or render targets. Popups or separate native windows are not part of the selected window's video. Minimized windows may stop producing fresh video; avoid minimizing during a recording.

ScreenCaptureKit's single-window filter restricts video to that window and audio to the owning application. Audio from other windows of the **same application** is included. `capturesAudio=true`, `excludesCurrentProcessAudio=false`, and `captureMicrophone=false` are explicit. This captures the application output mix after Bevy mixing, rather than a source PCM decoder tap. It is a stereo application mix, not a recording of speaker acoustics or every hardware/output-device transformation. Deepbore's music, radio and spatial effects must still be auditioned together before claiming audio parity.

Capture queue depth is three; there are no Rust frame queues, GPU readbacks, render-thread waits, or encoder pipe writes. ScreenCaptureKit owns asynchronous encoding, media timestamps, and its internal buffering. The API does not expose a strict total-memory bound, bitrate control, encoder occupancy, or dropped-frame counters. Slow rendering can reduce delivered cadence; timestamps retain real elapsed time. Test duration and A/V synchronization under load before production use.

This backend avoids both FFmpeg deployment and a custom AVAssetWriter timing/muxing implementation. The cost is macOS-only support, capture permission, an OS-managed encoder, and no headless recording. A future in-engine backend would need bounded nonblocking GPU readback plus access to the final audio mix; tapping individual sources would not suffice.

Primary references:

- [Apple: single-window capture and application-level audio policy](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Apple: SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput)
- [Apple: native recording introduced at WWDC24](https://developer.apple.com/videos/play/wwdc2024/10088/)
- [Apple: ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

## Files and failures

The destination must end in `.mp4` and must not already exist. The recorder atomically reserves `<output>.recording/` beside the destination, writes `capture.mp4` there, and publishes via a non-overwriting hard link only after the native success callback. Successful publication removes staging. Use a local filesystem supporting hard links (such as APFS). If publication fails, the finalized file stays in staging.

Disk/encoder/capture errors surface through `Failed`. A crash or failed recording can leave a partial or unplayable file in staging. Inspect it before manually deleting the staging directory to retry. Existing outputs are never intentionally overwritten. Missing output directories and unwritable locations return errors. No folders outside the destination's staging directory are removed.

## Development

```sh
cargo test --no-default-features
cargo test
cargo check --all-targets --features demo
cargo clippy --all-targets --features demo -- -D warnings
cargo fmt --all -- --check
```

Only macOS backend compilation is supported today. Dependency build concurrency can be limited with `-j 2`; no benchmark is needed. The native bridge compiles with warnings treated as errors. See [manual acceptance checks](VALIDATION.md) before integrating into a consumer game.
