# Status and next steps

The single place that says what is built, what is validated, what is blocked and how to carry on. **Read this first in a new session; update it whenever a change affects that picture.**

Last updated: 2026-10-19. Use this file for progress, blockers and next steps; use [docs/PRD.md](docs/PRD.md) for requirements and acceptance criteria. [README](README.md) owns setup/integration instructions; [VALIDATION](VALIDATION.md) owns detailed test evidence and the live checklist. Future progress updates should keep these roles consistent.

## Milestones

The plan and gates are in [docs/PRD.md](docs/PRD.md#milestones).

| Milestone | State | Commit / branch |
| --- | --- | --- |
| M0 · Foundations | Built; automated gate passed; pushed, not merged to main | `e738385` on `feat/macos-recorder` |
| M1 · Live recording | Gate waiting on Carlos's permission setup and live checks; no playable output verified | Same feature branch |
| M2 · Consumer integration | Planned; not started or authorized by this documentation task | No consumer changes |

## Revision and overall state

- Repository: [cjus/bevy-game-recorder](https://github.com/cjus/bevy-game-recorder).
- Working branch: [feat/macos-recorder](https://github.com/cjus/bevy-game-recorder/tree/feat/macos-recorder).
- Latest validated implementation commit: [e738385bea58b0388488fe48f2ac912796d94701](https://github.com/cjus/bevy-game-recorder/commit/e738385bea58b0388488fe48f2ac912796d94701), pushed and remote SHA verified. This tracking-document update sits on top of that baseline; use `git rev-parse HEAD` for the checkout's exact current documentation revision.
- **Implementation complete for the first version; live acceptance incomplete.** No release or main-branch merge has been performed.

## Completed implementation

- Reusable Rust session API and Bevy 0.20 plugin, independent of game logic; Rust 1.97.1 toolchain pinned.
- Opt-in demo `--record output.mp4`, animated scene, UI clock/status, test tone, stop/save and save/quit controls.
- macOS 15+ ScreenCaptureKit backend with exact native-window/current-PID selection, application audio enabled, microphone disabled, fixed output dimensions and asynchronous native encoding.
- Three-frame capture queue, native timestamps, staged output, no-overwrite publication, visible failure reporting and shutdown timeout handling.
- Independent review completed. Fixed late startup after cancellation and stale polling incorrectly overriding completed native output; regression coverage added.
- Locally built `BevyRecorderDemo.app` with explicit bundle ID, bundled tone asset and verified ad-hoc signature. It has not been launched via LaunchServices for live capture.

## Verified checks

On macOS 27.0 (26A428), Apple Silicon, Xcode SDK and rustup Rust 1.97.1:

| Check | Result |
| --- | --- |
| Rust tests with Bevy | 9 passed |
| Core-only Rust tests | 6 passed |
| Native lifecycle harness | Passed, without capture or permission requests |
| Clippy, all targets with demo, warnings denied | Passed |
| Rust formatting | Passed |
| Demo executable build and `--help` | Passed |
| Bundle plist and code signature | Passed |
| Existing permission preflight in the original unbundled execution context | False |

These are the recorded implementation checks, not new live-test claims. Full commands and the non-failing debug linker warning are in [VALIDATION](VALIDATION.md#automated-results).

## Blocker and unverified behavior

**Blocked on user-managed screen-and-system-audio recording permission and subsequent live testing.** No playable MP4 has been produced or verified. Application-audio isolation and audio/video synchronization are explicitly **unverified**. Composed UI capture, GUI indicator appearance, resize behavior, real encoder finalization, duration under load, native disk-error handling and Deepbore's final heard mix also remain unverified at runtime.

No permission prompt was triggered and no privacy setting changed. The unbundled preflight does not establish the bundled app's authorization; LaunchServices permission attribution has not been tested. The source and Apple API policy support the intended isolation, but are not substitutes for playback tests.

## Picking up

1. **User: add the specific demo bundle to permissions.** The current built bundle is:

   `/Users/cjus/Documents/Codex/2026-10-19/task/bevy-game-recorder/target/BevyRecorderDemo.app`

   In **System Settings → Privacy & Security → Screen & System Audio Recording**, click **+** under the screen-and-audio list, select that bundle, and enable **Bevy Recorder Demo**. Bundle ID: `dev.cjus.bevy-game-recorder-demo`; executable: `Contents/MacOS/bevy-recorder-demo`. Select screen-and-audio access, not audio-only. **A prior permission request is not required** when adding with **+**. See the canonical [permission instructions and Apple source](README.md#permission). Quit any running demo before relaunching. If rebuilding is needed, from the repository run `CARGO="$HOME/.cargo/bin/cargo" scripts/bundle-demo.sh`; rebuilding may require reauthorization.

2. **After the user handles permission: run the first recording test.** From this checkout:

   ```sh
   cd /Users/cjus/Documents/Codex/2026-10-19/task/bevy-game-recorder
   open "$PWD/target/BevyRecorderDemo.app" --args --record "$PWD/gameplay.mp4"
   ```

   Use an unused output name if `gameplay.mp4` already exists. Record about 15 seconds, press **Space**, wait for **Finished**, and play the file in QuickTime. Check animation/UI, audible tone, H.264, 1920×1080 output and duration against the demo clock. Do not mark playable output validated until playback succeeds.

3. Complete the [live acceptance checklist](VALIDATION.md#live-acceptance-checklist): application-audio isolation, A/V synchronization under load/static periods, resize, Escape/window-close finalization, denied permission and controlled file/encoder failures. Keep any test videos local. Record results, output paths and limitations in VALIDATION and summarize progress here; update PRD acceptance evidence only when supported.

4. **Planned, not started:** separately authorize and integrate into chessgui/deepbore-rs. Route consumer quit paths through the recorder and verify each game's rendering/UI and audio. Deepbore requires listening to music, radio and spatial effects together. Neither consumer repository has been modified by this work.
