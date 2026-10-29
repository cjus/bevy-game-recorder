# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0]

First public release.

- `RecordingSession` and `RecordingConfig`: record one window of the current process, with its application's audio, to an H.264 MP4 through ScreenCaptureKit's `SCRecordingOutput` (macOS 15+).
- `RecorderPlugin` and `Recorder` for Bevy 0.20: opt-in recording, visible state in the window title, `stop()` and `quit()`.
- The video shows the window's content without its title bar, in the window's shape within the configured size, and follows resizes and full screen.
- Window close, ⌘Q, the Dock's Quit, logout and Ctrl+C all finalize the MP4 before the app quits.
- Staged output with non-overwriting publication; failures are reported and partial output is kept for inspection.
- Demo app, permission preflight example and a script to build a signed demo bundle.

[Unreleased]: https://github.com/cjus/bevy-game-recorder/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/cjus/bevy-game-recorder/releases/tag/v0.1.0
