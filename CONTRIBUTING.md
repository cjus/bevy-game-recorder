# Contributing

Issues and pull requests are welcome. Recording behavior depends on macOS, the Mac's hardware and its permission state, so a bug report is most useful with the macOS version, chip, how the game was launched (terminal, `open`, Finder) and the `Recorder.state` it ended in.

## Development

Building requires macOS with Xcode command-line tools and a macOS 15+ SDK. `rust-toolchain.toml` pins the Rust version; use the rustup-managed `cargo` if your PATH has an older Homebrew Rust.

```sh
cargo fmt --all -- --check
cargo clippy --all-targets --features demo -- -D warnings
cargo test --no-default-features
cargo test
scripts/test-native.sh
```

CI runs the same commands on a macOS runner. The native bridge compiles with warnings treated as errors. `scripts/test-native.sh` exercises the Objective-C lifecycle against a real, never-shown `NSWindow` and a fake stream; it makes no capture or permission requests, so it runs without Screen Recording permission.

## Manual acceptance checks

Passing the automated checks doesn't prove a playable recording. Changes to the native bridge or the plugin's lifecycle should be checked live with the demo bundle, after granting it permission as described in the [README](README.md#permission):

1. Run without `--record`: no capture status or permission request; the tone and animation work.
2. Record about 15 seconds and press **Space**. Wait for Finished and play the MP4 in QuickTime: animated square, readable UI clock/status, audible tone, H.264, and a duration close to the elapsed wall time.
3. Record and resize the window, and try full screen: output dimensions stay fixed and aspect ratio is preserved.
4. Record while another app plays distinct audio: that audio is absent and the game's tone remains.
5. Record under a deliberately low frame rate and through a long static interval: duration stays real-time and audio stays in sync. Cadence may vary; time must not compress.
6. Quit with **Escape**, the window's close button, **⌘Q**, the Dock's **Quit** and **Ctrl+C** in the launching terminal, during both Starting and Recording: each shows Stopping, then quits with a playable MP4 or an explicit failure, never a false Finished. A second Ctrl+C exits at once.
7. Try denied or revoked permission, an existing output file, an unwritable or missing parent directory, and a full volume: errors are visible, existing files are untouched and staging is recoverable.

Mention which of these you ran in your pull request. Keep test recordings out of the repository; `*.mp4` is ignored.

## Releasing

Releases publish to crates.io from GitHub Actions through [trusted publishing](https://crates.io/docs/trusted-publishing); no API token is stored anywhere.

1. In a pull request, bump `version` in `Cargo.toml` and move the `Unreleased` notes in `CHANGELOG.md` under the new version.
2. After it merges, tag `main` and push the tag:

   ```sh
   git switch main && git pull
   git tag -a v0.2.0 -m "bevy-game-recorder 0.2.0"
   git push origin v0.2.0
   ```

3. The `Release` workflow checks that the tag matches `Cargo.toml` and runs `cargo publish`. It runs in the `release` environment, which only accepts `v*` tags.
4. Create the GitHub release from the tag with the changelog section as its notes.
