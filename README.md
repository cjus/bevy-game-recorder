# bevy-game-recorder

An opt-in Rust/Bevy recorder for **macOS 15+**, Bevy **0.20**, and Rust **1.97.1**. Records one game window, its composed UI, and that application's audio into a local H.264 MP4. No uploading, microphone capture, display-wide capture, or FFmpeg installation.

This is a first implementation, not a claim of validated support for a consumer game. See [validation](VALIDATION.md) for exactly what has been tested.

## Project tracking

Follow the same milestone/gate convention as the other Rust repositories: **built** does not mean the live gate has passed.

| File | Role |
| --- | --- |
| [docs/PRD.md](docs/PRD.md) | Requirements, scope, architecture decisions, milestones and acceptance criteria |
| [status.md](status.md) | Read first when resuming: completed work, verified checks, current revision, blockers and exact next steps |
| [VALIDATION.md](VALIDATION.md) | Detailed validation evidence and the remaining live acceptance checklist |
| This README | Setup, canonical permission instructions, demo commands and integration API |

Update status.md when progress changes and PRD.md when requirements or gates change. Live MP4 playback, application-audio isolation and A/V synchronization remain unverified; see [current status](status.md#blocker-and-unverified-behavior).

## Run the demo

Requires Xcode command-line tools with a macOS 15+ SDK. No runtime encoder executable is needed. Use the rustup-managed Cargo if your PATH contains an older Homebrew Rust.

```sh
cargo run --features demo --example demo
cargo run --features demo --example demo -- --record gameplay.mp4
```

Without `--record`, no capture or permission check occurs. The demo animates a square, renders a UI clock/status indicator, and plays a quiet looping 440 Hz tone. **Space** stops and saves; **Escape**, window close, **⌘Q** or **Ctrl+C** finalizes then quits. Keep the event loop running while “Stopping” is displayed. The title bar also shows recorder state. The demo's generated tone is included in `assets/tone.wav` and needs no download.

Default output: the window's content, without its title bar, so the title's recorder state and macOS's capture indicator stay out of the video; in the content's shape when recording starts, as large as fits in 1920×1080 (a window with 1440×900 points of content records 1730×1080, with no black bands), at most 30 fps, SDR H.264 MP4, stereo 48 kHz application audio. Apple controls bitrate and audio codec selection. Output dimensions stay fixed across window resizing and full screen, which the crop follows, with aspect ratio preserved. The window's rounded bottom corners show as small black corners. Recording is timestamped media with potentially variable frame cadence, not guaranteed constant-frame-rate output. A delayed frame does not remove elapsed time by advancing a raw frame counter.

## Permission

```sh
cargo run --no-default-features --example preflight
```

This only checks existing permission; it neither requests access nor makes the app appear automatically in Settings. For the unbundled `cargo run` command, macOS may attribute access to the responsible terminal/launcher rather than `target/debug/examples/demo`; the preflight does not identify that responsible app. Do not assume the Codex-hosted check describes permission in your Terminal session.

For an exact application identity, build the local bundle (does not launch or install it):

```sh
CARGO="$HOME/.cargo/bin/cargo" scripts/bundle-demo.sh
```

In **System Settings → Privacy & Security → Screen & System Audio Recording**, click **+** under the screen-and-audio list and select **`target/BevyRecorderDemo.app`** in this repository; enable **Bevy Recorder Demo**. Its bundle identifier is `dev.cjus.bevy-game-recorder-demo`, executable `Contents/MacOS/bevy-recorder-demo`. No prior programmatic permission request is needed when adding the app manually with **+** ([Apple instructions](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac)). Grant screen-and-audio access, not the audio-only option. Then launch that same bundle:

```sh
open "$PWD/target/BevyRecorderDemo.app" --args --record "$PWD/gameplay.mp4"
```

Quit any already running demo before relaunching; `open --args` does not deliver startup arguments to an existing process. The library never requests permission automatically or changes settings. The bundle is locally ad-hoc signed, not notarized; rebuilding can require reauthorization. Production apps should use a stable Developer ID signature. Bundle packaging and signature have been verified; permission attribution through an actual LaunchServices launch remains untested because we have not launched capture or changed permissions.

## Integrate

```toml
[dependencies]
bevy-game-recorder = { path = "../bevy-game-recorder" }
```

```rust,no_run
use bevy::{app::TerminalCtrlCHandlerPlugin, prelude::*, window::ExitCondition};
use bevy_game_recorder::{RecorderPlugin, RecordingConfig};

let requested_output: Option<String> = None; // Populate from your own CLI parser.
let config = requested_output.map(|path| RecordingConfig::new(path, "My Game"));
App::new()
    .add_plugins(
        DefaultPlugins
            .set(WindowPlugin {
                primary_window: Some(Window { title: "My Game".into(), ..default() }),
                close_when_requested: false,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .disable::<TerminalCtrlCHandlerPlugin>(),
    )
    .add_plugins(RecorderPlugin(config))
    .run();
```

The plugin expects a primary window with an exact, unique native title at startup, waits three update frames for creation, and verifies the selected native window belongs to the current process. Failure to resolve it fails closed. It does not fall back to a display or another application's window. Install after `DefaultPlugins`. Avoid changing the primary title independently; the recorder appends its visible status, which the player sees and the video doesn't. Add an in-game indicator based on `Recorder.state` if the title bar is hidden (see demo); it will be in the video.

Use `ResMut<Recorder>::stop()` to save without quitting, or `quit()` to save and quit. Route **all** game quit/menu actions through `quit()`. Direct `AppExit`, `process::exit`, panic/abort, force quit and signals other than Ctrl+C bypass graceful finalization. The plugin handles the rest of the ways to quit:

- **Window close**: automatic window destruction and automatic exit must be disabled as above. Other windows' close handling remains the consumer's responsibility.
- **⌘Q, the Dock's Quit, logout and shutdown** (`-[NSApplication terminate:]`): while a recording is unfinished, macOS's quit is refused (`applicationShouldTerminate:` answers `NSTerminateCancel`, added to winit's application delegate when recording starts) and becomes `quit()`. Once the recording is finished or has failed, quitting goes ahead as usual. A logout or shutdown is cancelled by the refusal; the user starts it again after the app has quit.
- **Ctrl+C** in the terminal: the plugin sets the process's Ctrl+C handler and turns Ctrl+C into `quit()`. Bevy's `TerminalCtrlCHandlerPlugin`, part of `DefaultPlugins`, would write `AppExit` at once, so it must be disabled as above (the plugin panics otherwise, as it does for the window settings). A second Ctrl+C exits at once without finalizing, as with Bevy's handler.

While a recording is starting or stopping, the plugin asks for frames (`RequestRedraw`), so a reactive update mode keeps polling it.

`Recorder.state` exposes Starting, Recording, Stopping, Finished or Failed(error); None means disabled. Check failures and surface them to players. Stopping is nonblocking. Start/finalization times out after 30 seconds of polling, reports failure, and preserves partial output rather than claiming success. There is one recording session per process in this first version; restart to record again.

For custom integration without Bevy, disable default features and use `RecordingSession` on the macOS main thread. Continue pumping the native event loop and calling `poll()` until terminal. `Drop` aborts unfinished native work, including pending discovery; it cannot promise finalization. Continue polling after `stop()` to save successfully.

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
scripts/test-native.sh
```

Only macOS backend compilation is supported today. Dependency build concurrency can be limited with `-j 2`; no benchmark is needed. The native bridge compiles with warnings treated as errors. See [manual acceptance checks](VALIDATION.md) before integrating into a consumer game.
