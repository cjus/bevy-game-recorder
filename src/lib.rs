//! Opt-in macOS 15+ recording of one game window and its application's audio.
//! See README for permission, lifecycle and integration requirements.
use std::{ffi::CString, marker::PhantomData, path::PathBuf, rc::Rc};

#[cfg(feature = "bevy")]
mod plugin;
#[cfg(feature = "bevy")]
pub use plugin::{Recorder, RecorderPlugin};

/// Fixed output configuration. Source window resizing does not change output size.
#[derive(Clone, Debug)]
pub struct RecordingConfig {
    pub output: PathBuf,
    /// Exact, unique visible NSWindow title in this process at recording startup.
    pub window_title: String,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    /// Capture this application's final OS audio mix, never the microphone.
    pub audio: bool,
}
impl RecordingConfig {
    pub fn new(output: impl Into<PathBuf>, window_title: impl Into<String>) -> Self {
        Self {
            output: output.into(),
            window_title: window_title.into(),
            width: 1920,
            height: 1080,
            fps: 30,
            audio: true,
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.width == 0
            || self.height == 0
            || self.width > 3840
            || self.height > 2160
            || !self.width.is_multiple_of(2)
            || !self.height.is_multiple_of(2)
        {
            return Err("H.264 dimensions must be even and within 3840x2160".into());
        }
        if !(1..=60).contains(&self.fps) {
            return Err("fps must be between 1 and 60".into());
        }
        if self.window_title.is_empty() || CString::new(self.window_title.as_str()).is_err() {
            return Err("window title must be nonempty without NUL".into());
        }
        if self.output.extension().and_then(|s| s.to_str()) != Some("mp4") {
            return Err("output must have .mp4 extension".into());
        }
        Ok(())
    }
}
/// Native asynchronous lifecycle. Only `Finished` means MP4 finalization succeeded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecordingState {
    Starting,
    Recording,
    Stopping,
    Finished,
    Failed(String),
}
impl RecordingState {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Finished | Self::Failed(_))
    }
}

/// One recording per process. Use from the macOS main thread only.
/// Poll while the event loop continues running; stop is asynchronous.
pub struct RecordingSession {
    output: PathBuf,
    staging: PathBuf,
    state: RecordingState,
    transition_at: std::time::Instant,
    _main_thread: PhantomData<Rc<()>>,
}
#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn bgr_preflight() -> i32;
    fn bgr_is_main_thread() -> i32;
    fn bgr_start(
        path: *const std::ffi::c_char,
        title: *const std::ffi::c_char,
        width: i32,
        height: i32,
        fps: i32,
        audio: i32,
    ) -> i32;
    fn bgr_state() -> i32;
    fn bgr_error() -> *const std::ffi::c_char;
    fn bgr_stop();
    fn bgr_take_quit_request() -> i32;
    fn bgr_abort();
}
impl RecordingSession {
    /// Does not display a permission prompt or change privacy settings.
    pub fn permission_available() -> bool {
        #[cfg(target_os = "macos")]
        // SAFETY: CoreGraphics preflight has no arguments or ownership requirements.
        unsafe {
            bgr_preflight() != 0
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }
    pub fn start(config: &RecordingConfig) -> Result<Self, String> {
        config.validate()?;
        #[cfg(not(target_os = "macos"))]
        return Err("Recording currently requires macOS 15+".into());
        #[cfg(target_os = "macos")]
        {
            // SAFETY: thread predicate has no arguments or side effects.
            if unsafe { bgr_is_main_thread() } == 0 {
                return Err("Recording must start on the macOS main thread".into());
            }
            if !Self::permission_available() {
                return Err("Enable the game/launching terminal in System Settings > Privacy & Security > Screen & System Audio Recording and restart. Permission was not requested automatically.".into());
            }
            let output = std::path::absolute(&config.output).map_err(|e| e.to_string())?;
            if output.exists() {
                return Err("Refusing to overwrite existing output".into());
            }
            let mut staging_name = output.as_os_str().to_owned();
            staging_name.push(".recording");
            let staging = PathBuf::from(staging_name);
            let path = CString::new(
                staging
                    .join("capture.mp4")
                    .to_str()
                    .ok_or("Output path must be UTF-8")?,
            )
            .map_err(|e| e.to_string())?;
            let title = CString::new(config.window_title.as_str()).map_err(|e| e.to_string())?;
            std::fs::create_dir(&staging)
                .map_err(|e| format!("Cannot reserve recording directory: {e}"))?;
            // SAFETY: owned C strings remain valid for this call; native code copies
            // them before returning. Main-thread requirement is enforced natively.
            let result = unsafe {
                bgr_start(
                    path.as_ptr(),
                    title.as_ptr(),
                    config.width as i32,
                    config.height as i32,
                    config.fps as i32,
                    i32::from(config.audio),
                )
            };
            if result != 0 {
                let _ = std::fs::remove_dir(&staging);
                return Err("Only one recording session is supported per process".into());
            }
            Ok(Self {
                output,
                staging,
                state: RecordingState::Starting,
                transition_at: std::time::Instant::now(),
                _main_thread: PhantomData,
            })
        }
    }
    pub fn stop(&mut self) {
        if self.state.is_terminal() || self.state == RecordingState::Stopping {
            return;
        }
        #[cfg(target_os = "macos")]
        // SAFETY: this !Send session is polled on its creating main thread.
        unsafe {
            bgr_stop();
        }
        self.state = RecordingState::Stopping;
        self.transition_at = std::time::Instant::now();
    }
    /// Whether macOS was asked to quit the app (⌘Q, the Dock's Quit, logout) since the last
    /// call. While the session is unfinished the native quit is refused, so the MP4 can be
    /// finalized: call `stop()`, keep polling, and quit once the state is terminal.
    pub fn take_quit_request(&mut self) -> bool {
        #[cfg(target_os = "macos")]
        // SAFETY: this !Send session is polled on its creating main thread.
        unsafe {
            bgr_take_quit_request() != 0
        }
        #[cfg(not(target_os = "macos"))]
        {
            false
        }
    }
    pub fn poll(&mut self) -> &RecordingState {
        if self.state.is_terminal() {
            return &self.state;
        }
        #[cfg(target_os = "macos")]
        // SAFETY: read main-thread native state before evaluating elapsed time.
        let native_state = unsafe { bgr_state() };
        #[cfg(not(target_os = "macos"))]
        let native_state = 5;
        if transition_timed_out(&self.state, native_state, self.transition_at.elapsed()) {
            #[cfg(target_os = "macos")]
            // SAFETY: this session remains on its creating main thread.
            unsafe {
                bgr_abort();
            }
            self.state = RecordingState::Failed(format!(
                "Native start/finalization timed out; any partial output remains in {}",
                self.staging.display()
            ));
            return &self.state;
        }
        #[cfg(target_os = "macos")]
        // SAFETY: native singleton remains alive; error pointer is copied on the
        // main thread before another callback can mutate the NSString.
        unsafe {
            self.state = match native_state {
                1 => {
                    if self.state == RecordingState::Stopping {
                        RecordingState::Stopping
                    } else {
                        RecordingState::Starting
                    }
                }
                2 => RecordingState::Recording,
                3 => RecordingState::Stopping,
                4 => match publish(&self.staging, &self.output) {
                    Ok(()) => RecordingState::Finished,
                    Err(e) => RecordingState::Failed(format!(
                        "MP4 finalized in {}; could not publish without overwriting: {e}",
                        self.staging.display()
                    )),
                },
                _ => RecordingState::Failed(
                    std::ffi::CStr::from_ptr(bgr_error())
                        .to_string_lossy()
                        .into_owned(),
                ),
            };
        }
        &self.state
    }
}
fn transition_timed_out(
    state: &RecordingState,
    native_state: i32,
    elapsed: std::time::Duration,
) -> bool {
    matches!(state, RecordingState::Starting | RecordingState::Stopping)
        && matches!(native_state, 1 | 3)
        && elapsed > std::time::Duration::from_secs(30)
}
fn publish(staging: &std::path::Path, output: &std::path::Path) -> std::io::Result<()> {
    std::fs::hard_link(staging.join("capture.mp4"), output)?;
    let _ = std::fs::remove_file(staging.join("capture.mp4"));
    let _ = std::fs::remove_dir(staging);
    Ok(())
}
impl Drop for RecordingSession {
    fn drop(&mut self) {
        if !self.state.is_terminal() {
            #[cfg(target_os = "macos")]
            // SAFETY: ownership is !Send; cancel even a pending asynchronous start.
            unsafe {
                bgr_abort();
            }
        }
    } // Dropping early cancels; poll to completion to guarantee finalization.
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_progress_wins_over_stale_polling_deadline() {
        let late = std::time::Duration::from_secs(60);
        for native in [2, 4, 5] {
            assert!(!transition_timed_out(
                &RecordingState::Starting,
                native,
                late
            ));
            assert!(!transition_timed_out(
                &RecordingState::Stopping,
                native,
                late
            ));
        }
        assert!(transition_timed_out(&RecordingState::Starting, 1, late));
        assert!(transition_timed_out(&RecordingState::Stopping, 3, late));
        assert!(!transition_timed_out(
            &RecordingState::Stopping,
            3,
            std::time::Duration::from_secs(2)
        ));
    }
    #[test]
    fn defaults_are_shareable() {
        let c = RecordingConfig::new("game.mp4", "Game");
        assert!(c.validate().is_ok());
        assert_eq!((c.width, c.height, c.fps, c.audio), (1920, 1080, 30, true));
    }
    #[test]
    fn rejects_bad_dimensions_and_rate() {
        for (w, h, f) in [
            (0, 1080, 30),
            (1919, 1080, 30),
            (1920, 1081, 30),
            (4096, 2160, 30),
            (1920, 1080, 0),
            (1920, 1080, 61),
        ] {
            let mut c = RecordingConfig::new("x.mp4", "Game");
            c.width = w;
            c.height = h;
            c.fps = f;
            assert!(c.validate().is_err());
        }
    }
    #[test]
    fn rejects_bad_names() {
        for (path, title) in [("x.mov", "Game"), ("x.mp4", ""), ("x.mp4", "bad\0title")] {
            assert!(RecordingConfig::new(path, title).validate().is_err());
        }
    }
    #[test]
    fn publication_never_clobbers_existing_files() {
        let root = std::env::temp_dir().join(format!("bgr-test-{}", std::process::id()));
        let staging = root.join("staging");
        std::fs::create_dir_all(&staging).unwrap();
        let target = root.join("target.mp4");
        std::fs::write(&target, b"original").unwrap();
        std::fs::write(staging.join("capture.mp4"), b"new").unwrap();
        assert!(publish(&staging, &target).is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"original");
        assert_eq!(std::fs::read(staging.join("capture.mp4")).unwrap(), b"new");
        std::fs::remove_file(&target).unwrap();
        publish(&staging, &target).unwrap();
        assert_eq!(std::fs::read(&target).unwrap(), b"new");
        assert!(!staging.exists());
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn terminal_states() {
        assert!(RecordingState::Finished.is_terminal());
        assert!(RecordingState::Failed("disk full".into()).is_terminal());
        assert!(!RecordingState::Stopping.is_terminal());
    }
}
