# Bevy Game Recorder — Product Requirements

Owner: Carlos. Repository: `cjus/bevy-game-recorder`.
Status: M0 is built and its automated gate has passed; M1 waits on permission and live testing.
Last updated: 2026-10-24.

This file defines requirements, scope and acceptance criteria. [status.md](../status.md) tracks progress, evidence, blockers and next steps. [README](../README.md) is the operational reference for setup and integration; [VALIDATION](../VALIDATION.md) records executed checks and the live acceptance procedure. An implemented requirement is not automatically a validated requirement.

## Overview

Provide a reusable recording library independent of game logic. An optional startup flag such as `--record gameplay.mp4` records gameplay into a local shareable video. The initial target is macOS 15+, Bevy 0.20 and Rust 1.97.1, with a runnable demonstration application.

The first version covers one selected game window and one recording session per process. Intended future consumers are chessgui and deepbore-rs. Neither consumer has been modified or integrated; each integration is separate planned work after recorder validation and authorization.

Out of scope: Windows/Linux capture, headless recording, uploading, microphone capture, unrelated applications, multi-window video, repeated sessions without restart, encoder bitrate control, releases, and force-quit recovery guarantees.

## Requirements and acceptance criteria

| Requirement | Acceptance criterion | Current evidence |
| --- | --- | --- |
| Opt-in recording | Without the flag, no capture session or permission request starts. | Disabled-plugin test passes; GUI behavior awaits live checks. |
| Composed output | Video contains the selected game's final rendering and UI, never another application's window. | Native window ID and current PID checks reviewed; actual video unverified. |
| Shareable video | A finalized, playable SDR H.264 MP4 defaults to 1920×1080, up to 30 fps. | Native configuration and build verified; playable MP4 unverified. |
| Fixed dimensions | The video takes the window's shape at the start, within the configured size (#3); resizing preserves output dimensions and source aspect ratio. | Native configuration reviewed; resize recording unverified. |
| Recording indicator | Visible state distinguishes preparing, recording, finalizing, saved and failure. | Title status and demo UI implemented; visual validation pending. |
| Responsive capture | Capture and encoding do not block the render thread; capture queue is bounded. | Three-frame ScreenCaptureKit queue; no Rust frame queues, GPU waits or pipe writes. OS encoder internals have no exposed total-memory bound. |
| Correct timing | Late/static frames preserve elapsed duration; audio/video remain synchronized under load. | Native timestamps used; duration and A/V sync unverified. Variable cadence is allowed; exact CFR is not required. |
| Application audio | The game application's output mix is audible and unrelated application audio is absent; microphone remains disabled. | Window filter policy and explicit configuration reviewed; audible mix and audio isolation unverified. |
| Graceful stop/quit | Normal stop, Escape, window close, ⌘Q, the Dock's Quit and Ctrl+C wait for finalization before reporting Saved or exiting. | Lifecycle regression tests pass, including AppKit's `terminate:` refused while unfinished and Ctrl+C turned into `quit()` (#1); real encoder finalization and playback pending. |
| Safe failures | Permission, window-selection, encoder, disk and destination errors are visible; existing files are not overwritten. | Validation/no-clobber/lifecycle tests pass; native failure scenarios need live checks. |
| Local-only files | Completed video remains at the requested local destination; partial output is identified honestly. | Local staging and non-overwriting publication implemented; no upload path exists. |

For the first live acceptance recording, record approximately 15 seconds, wait for Finished, play it in QuickTime, and compare duration with the demo clock. Follow the full [live checklist](../VALIDATION.md#live-acceptance-checklist), including resize, timing under load, application-audio isolation and failures. Record measured results before marking these criteria validated. Deepbore's music, radio and spatial effects must later be auditioned together; a silent recording or source-PCM tap is not sufficient evidence.

## Architecture and decisions

1. `RecordingConfig` and the main-thread `RecordingSession` provide a Rust API independent of game logic. `RecorderPlugin` bridges startup, visible status, stop and quit into Bevy. Consumers must route quit actions through `Recorder::quit()` and disable automatic window destruction/exit as described in [integration](../README.md#integrate).
2. A small Objective-C ARC bridge selects exactly one visible native window with the configured title, rechecks its window ID and owning PID, then uses a desktop-independent window filter. Selection failure never falls back to display capture.
3. ScreenCaptureKit owns capture, media timestamps and asynchronous H.264 MP4 encoding through `SCRecordingOutput`. Fixed dimensions, aspect preservation, queue depth three and 30 fps maximum cadence are configured explicitly. This avoids FFmpeg deployment and custom blocking GPU readback or pipe writes.
4. Audio uses the owning application's mix, including its other windows, with current-process audio included and microphone capture disabled. It does not promise speaker acoustics or every output-device transformation. See [backend rationale and Apple references](../README.md#backend-and-audio-tradeoffs).
5. Output is staged in `<output>.recording/capture.mp4`. Only the native finish callback permits publication by a non-overwriting hard link. Failures preserve staging for inspection. A local hard-link-capable filesystem such as APFS is required.
6. Terminal state is immutable; cancellation prevents late discovery/start from reviving capture. Rust observes native progress before evaluating its polling deadline. Start/stop timeout or early drop aborts unfinished native work; force termination cannot guarantee a usable MP4.

The chosen tradeoff is macOS capture permission and OS-managed encoder controls in exchange for composed window output and access to application audio without Bevy-private audio internals. An in-engine backend would require separate work on bounded GPU readback and the final audio mix.

## Permission and privacy contract

Recording never grants or requests permission automatically. The user enables **Bevy Recorder Demo.app** manually under Screen & System Audio Recording; the exact bundle identity, Settings steps and launch command are maintained in [README → Permission](../README.md#permission), with the current local path and next action in [status.md](../status.md#picking-up). No prior prompt is required when adding the bundle with Settings **+**. Rebuilding its ad-hoc signature may require reauthorization.

Do not equate the unbundled preflight result with the permission state of a separately launched app bundle. Live capture must remain pending until the user handles permission. No permission settings, unrelated applications, or consumer repositories are changed as part of this tracking update.

## Milestones

| Milestone | Scope | Gate | State |
| --- | --- | --- | --- |
| M0 · Foundations | Library, native backend, Bevy plugin, demo, integration docs and regression checks | Build, tests, Clippy, formatting and bundle checks pass | Built; automated gate passed on the baseline in status.md; pushed to the feature branch, not merged |
| M1 · Live recording | Playable output, composed UI, application-audio isolation, synchronization, resize and real shutdown/errors | Complete VALIDATION's live checklist and record evidence | Waiting on Carlos's permission setup, then live tests |
| M2 · Consumer integration | Separately authorized chessgui and deepbore-rs integration | Each consumer's rendering, audio and quit paths pass their own checks | chessgui started (cjus/chessgui#175, 2026-10-24); deepbore-rs not started |

## Risks

- Screen recording permission depends on launch identity; an unbundled terminal preflight does not prove bundle authorization. Ad-hoc rebuilding may require reauthorization.
- The encoder is OS-managed, with opaque internal buffering and no strict total-memory or bitrate control. Cadence, duration and synchronization must be measured under load.
- Main-loop exit, force termination or an unrouted consumer quit can prevent MP4 finalization. Graceful quit integration is a requirement, not an automatic guarantee.
- Protected/minimized window behavior and audio routing require live validation. Deepbore audio parity remains a separate consumer gate.

## Decisions

| Date | Decision | Reason |
| --- | --- | --- |
| 2026-10-19 | macOS 15+ first, with ScreenCaptureKit and SCRecordingOutput | User accepted Apple-only scope; native composed-window and application-audio capture avoids private Bevy mix internals and FFmpeg deployment |
| 2026-10-19 | Keep output local, microphone disabled, window and PID checked | Recording scope is the selected game window and its application's audio |
| 2026-10-19 | Provide a named demo app bundle | Makes the manual permission target explicit; no automatic permission requests |
| 2026-10-24 | The video takes the window's shape when recording starts, within `width` × `height` (#3) | Carlos chose it over 16:9 with bands after Solrac's first recordings showed a band down one side |
| 2026-10-24 | The plugin owns every normal way to quit: window close, `terminate:` (⌘Q, Dock, logout) and Ctrl+C (#1) | Consumers can't refuse `terminate:` or replace Bevy's Ctrl+C handler without native code; Solrac forbids `unsafe` |
| 2026-10-19 | Track requirements here and progress in root status.md | Follow the Rust repositories' milestone/gate conventions while keeping the user-requested paths |

## Open questions

- Does live capture pass duration, A/V synchronization and isolation checks on the target Mac and output route?
- Does each consumer need title-selection customization, additional quit handling or a dedicated in-game indicator?
- Is one recording session per process sufficient after initial consumer use? Additional sessions and platforms remain future scope.
