# bevy-game-recorder

[![CI](https://github.com/cjus/bevy-game-recorder/actions/workflows/ci.yml/badge.svg)](https://github.com/cjus/bevy-game-recorder/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

An opt-in recorder for [Bevy](https://bevyengine.org) games on **macOS 15+**. It records one game window, its composed UI, and that application's audio into a local H.264 MP4, using Apple's ScreenCaptureKit. No uploading, microphone capture, display-wide capture, or FFmpeg installation.

| Requirement | Version |
| --- | --- |
| macOS | 15 or later (ScreenCaptureKit's `SCRecordingOutput`) |
| Bevy | 0.20 |
| Rust | 1.97.1 (pinned in `rust-toolchain.toml`) |
| Build tools | Xcode command-line tools with a macOS 15+ SDK |

This is an early release. See [Status and known limitations](#status-and-known-limitations) for what has and hasn't been verified live.

## Run the demo

```sh
cargo run --features demo --example demo
cargo run --features demo --example demo -- --record gameplay.mp4
```

Without `--record`, no capture or permission check occurs. The demo animates a square, renders a UI clock/status indicator, and plays a quiet looping 440 Hz tone (`assets/tone.wav`). **Space** stops and saves; **Escape**, window close, **⌘Q** or **Ctrl+C** finalizes then quits. Keep the event loop running while "Stopping" is displayed. The title bar also shows recorder state.

Default output: the window's content, without its title bar, so the title's recorder state and macOS's capture indicator stay out of the video; in the content's shape when recording starts, as large as fits in 1920×1080 (a window with 1440×900 points of content records 1730×1080, with no black bands), at most 30 fps, SDR H.264 MP4, stereo 48 kHz application audio. Apple controls bitrate and audio codec selection. Output dimensions stay fixed across window resizing and full screen, which the crop follows, with aspect ratio preserved. The window's rounded bottom corners show as small black corners. Recording is timestamped media with potentially variable frame cadence, not guaranteed constant-frame-rate output. A delayed frame does not remove elapsed time.

## Permission

Recording needs **Screen & System Audio Recording** permission. The library never requests permission or changes settings itself. To check the current state:

```sh
cargo run --no-default-features --example preflight
```

This only checks existing permission; it neither requests access nor makes the app appear in Settings. For an unbundled `cargo run`, macOS may attribute access to the responsible terminal or launcher rather than `target/debug/examples/demo`, and the preflight does not identify which app that is.

For an exact application identity, build the local demo bundle (this does not launch or install it):

```sh
scripts/bundle-demo.sh
```

Set `CARGO=...` if the `cargo` on your PATH isn't the rustup-managed one.

In **System Settings → Privacy & Security → Screen & System Audio Recording**, click **+** under the screen-and-audio list, select **`target/BevyRecorderDemo.app`** in this repository, and enable **Bevy Recorder Demo** ([Apple instructions](https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac)). Its bundle identifier is `dev.cjus.bevy-game-recorder-demo`. Grant screen-and-audio access, not the audio-only option. Then launch that same bundle:

```sh
open "$PWD/target/BevyRecorderDemo.app" --args --record "$PWD/gameplay.mp4"
```

Quit any already running demo before relaunching; `open --args` does not deliver arguments to an existing process. The bundle is ad-hoc signed, not notarized, so rebuilding can require reauthorization. Shipping games should use a stable Developer ID signature.

## Integrate

```toml
[dependencies]
bevy-game-recorder = "0.1"
# or, before a crates.io release:
# bevy-game-recorder = { git = "https://github.com/cjus/bevy-game-recorder" }
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

The plugin expects a primary window with an exact, unique native title at startup, waits three update frames for creation, and verifies the selected native window belongs to the current process. Failure to resolve it fails closed. It does not fall back to a display or another application's window. Install after `DefaultPlugins`. Avoid changing the primary title independently; the recorder appends its visible status, which the player sees and the video doesn't. Add an in-game indicator based on `Recorder.state` if the title bar is hidden (see the demo); it will be in the video.

Use `ResMut<Recorder>::stop()` to save without quitting, or `quit()` to save and quit. Route **all** game quit/menu actions through `quit()`. Direct `AppExit`, `process::exit`, panic/abort, force quit and signals other than Ctrl+C bypass graceful finalization. The plugin handles the rest of the ways to quit:

- **Window close**: automatic window destruction and automatic exit must be disabled as above. Other windows' close handling remains your responsibility.
- **⌘Q, the Dock's Quit, logout and shutdown** (`-[NSApplication terminate:]`): while a recording is unfinished, macOS's quit is refused (`applicationShouldTerminate:` answers `NSTerminateCancel`, added to winit's application delegate when recording starts) and becomes `quit()`. Once the recording is finished or has failed, quitting goes ahead as usual. A logout or shutdown is cancelled by the refusal; the user starts it again after the app has quit.
- **Ctrl+C** in the terminal: the plugin sets the process's Ctrl+C handler and turns Ctrl+C into `quit()`. Bevy's `TerminalCtrlCHandlerPlugin`, part of `DefaultPlugins`, would write `AppExit` at once, so it must be disabled as above (the plugin panics otherwise, as it does for the window settings). A second Ctrl+C exits at once without finalizing, as with Bevy's handler.

While a recording is starting or stopping, the plugin asks for frames (`RequestRedraw`), so a reactive update mode keeps polling it.

`Recorder.state` exposes Starting, Recording, Stopping, Finished or Failed(error); None means disabled. Check failures and surface them to players. Stopping is nonblocking. Start/finalization times out after 30 seconds of polling, reports failure, and preserves partial output rather than claiming success. There is one recording session per process; restart to record again.

### Without Bevy

Disable default features and use `RecordingSession` on the macOS main thread. Continue pumping the native event loop and calling `poll()` until the state is terminal. Continue polling after `stop()` to save successfully. `Drop` aborts unfinished native work, including pending discovery; it cannot promise finalization.

## Files and failures

The destination must end in `.mp4` and must not already exist. The recorder atomically reserves `<output>.recording/` beside the destination, writes `capture.mp4` there, and publishes via a non-overwriting hard link only after the native success callback. Successful publication removes staging. Use a local filesystem supporting hard links (such as APFS). If publication fails, the finalized file stays in staging.

Disk, encoder and capture errors surface through `Failed`. A crash or failed recording can leave a partial or unplayable file in staging. Inspect it before manually deleting the staging directory to retry. Existing outputs are never intentionally overwritten. Missing output directories and unwritable locations return errors. No folders outside the destination's staging directory are removed.

## How it works

A small Objective-C ARC bridge (`native/recorder.m`) uses `SCContentFilter(desktopIndependentWindow:)`, `SCStream`, and `SCRecordingOutput`. This captures final window compositing regardless of Bevy cameras or render targets. Popups or separate native windows are not part of the selected window's video. Minimized windows may stop producing fresh video; avoid minimizing during a recording.

ScreenCaptureKit's single-window filter restricts video to that window and audio to the owning application. Audio from other windows of the **same application** is included. `capturesAudio=true`, `excludesCurrentProcessAudio=false`, and `captureMicrophone=false` are explicit. This captures the application output mix after Bevy mixing, rather than a source PCM tap. It is a stereo application mix, not a recording of speaker acoustics or every output-device transformation.

Capture queue depth is three; there are no Rust frame queues, GPU readbacks, render-thread waits, or encoder pipe writes. ScreenCaptureKit owns asynchronous encoding, media timestamps, and its internal buffering. The API does not expose a strict total-memory bound, bitrate control, encoder occupancy, or dropped-frame counters. Slow rendering can reduce delivered cadence; timestamps retain real elapsed time.

This backend avoids both FFmpeg deployment and a custom AVAssetWriter timing/muxing implementation. The cost is macOS-only support, capture permission, an OS-managed encoder, and no headless recording. A future in-engine backend would need bounded nonblocking GPU readback plus access to the final audio mix; tapping individual sources would not suffice.

References:

- [Apple: single-window capture and application-level audio policy (WWDC22)](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Apple: SCRecordingOutput](https://developer.apple.com/documentation/screencapturekit/screcordingoutput)
- [Apple: native recording introduced at WWDC24](https://developer.apple.com/videos/play/wwdc2024/10088/)
- [Apple: ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

## Status and known limitations

**Verified live** in a real Bevy game on macOS 27.0, Apple Silicon:

- Playable H.264 MP4s with AAC 48 kHz stereo application audio, at about 29.5 fps.
- Content-only output: no title bar, title text or capture indicator; a 1440×900-point content area recorded 1730×1080 with no black bands.
- Finalization through macOS's quit request (the ⌘Q path) and Ctrl+C, each Stopping → Finished in under 0.1 s, with the file published and no staging left behind.

**Covered by automated tests only**: crop tracking during resize and full screen, AppKit's `terminate:` being refused while a session is unfinished, cancellation and late-callback handling, no-clobber publication.

**Not yet verified live**: finalization via the window's close button and Escape, resizing or full screen while recording, minimizing, denied or revoked permission, isolation from other applications' audio, A/V synchronization under heavy load, and disk-full or encoder failures. Reports are welcome; see [CONTRIBUTING](CONTRIBUTING.md#manual-acceptance-checks).

**Known limitations**:

- macOS 15+ only. Non-macOS stubs return an error from `start()`, but only macOS builds are tested.
- One recording session per process.
- The window's rounded bottom corners show as small black corners.
- A game started as a background job of a non-interactive shell inherits SIGINT ignored, so Ctrl+C can't save the recording. A terminal's foreground job, or `set -m`, is fine.
- Force quit, `kill -9`, panics and direct `AppExit` can't finalize the MP4.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development commands and the manual acceptance checklist.

## License

[MIT](LICENSE)
