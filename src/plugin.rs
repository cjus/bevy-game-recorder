use crate::{RecordingConfig, RecordingSession, RecordingState};
#[cfg(any(unix, windows))]
use bevy::app::TerminalCtrlCHandlerPlugin;
use bevy::{
    app::AppExit,
    prelude::*,
    window::{ExitCondition, PrimaryWindow, RequestRedraw, WindowCloseRequested, WindowPlugin},
};
use std::sync::atomic::{AtomicBool, Ordering};

/// Set by the process's Ctrl+C handler (`handle_ctrl_c`), taken by `drive_recorder`.
static CTRL_C: AtomicBool = AtomicBool::new(false);

/// Install after DefaultPlugins; configure WindowPlugin as shown in README.
pub struct RecorderPlugin(pub Option<RecordingConfig>);
/// Control recording and read its current status. `None` means disabled.
#[derive(Resource, Default)]
pub struct Recorder {
    pub state: Option<RecordingState>,
    stop_requested: bool,
    quit_requested: bool,
}
impl Recorder {
    pub fn stop(&mut self) {
        self.stop_requested = true;
    }
    /// Use instead of sending AppExit while recording, so the MP4 can finalize.
    pub fn quit(&mut self) {
        self.stop_requested = true;
        self.quit_requested = true;
    }
}
struct NativeRecorder {
    config: Option<RecordingConfig>,
    session: Option<RecordingSession>,
    started: bool,
    frames: u8,
}
impl Plugin for RecorderPlugin {
    fn build(&self, app: &mut App) {
        let windows = app.get_added_plugins::<WindowPlugin>();
        assert!(
            windows
                .iter()
                .any(|p| !p.close_when_requested
                    && matches!(p.exit_condition, ExitCondition::DontExit)),
            "RecorderPlugin requires WindowPlugin close_when_requested=false and exit_condition=DontExit; see README"
        );
        #[cfg(any(unix, windows))]
        {
            assert!(
                app.get_added_plugins::<TerminalCtrlCHandlerPlugin>()
                    .is_empty(),
                "RecorderPlugin handles Ctrl+C itself: disable TerminalCtrlCHandlerPlugin; see README"
            );
            handle_ctrl_c();
        }
        app.init_resource::<Recorder>()
            .insert_non_send(NativeRecorder {
                config: self.0.clone(),
                session: None,
                started: false,
                frames: 0,
            })
            .add_systems(Update, drive_recorder);
    }
}
/// Ctrl+C becomes a graceful `quit()`. Bevy's own handler would write `AppExit` at once, before
/// the MP4 is finalized. A second Ctrl+C exits at once, as Bevy's does: `gracefully_exit` exits
/// on its second call, and its first wakes a reactive event loop (bevy_winit registers that).
#[cfg(any(unix, windows))]
fn handle_ctrl_c() {
    static INSTALL: std::sync::Once = std::sync::Once::new();
    INSTALL.call_once(|| {
        let handler = || {
            CTRL_C.store(true, Ordering::SeqCst);
            TerminalCtrlCHandlerPlugin::gracefully_exit();
        };
        if let Err(e) = bevy::app::ctrlc::try_set_handler(handler) {
            warn!("Ctrl+C will quit without finalizing a recording: {e}");
        }
    });
}
fn drive_recorder(
    mut native: NonSendMut<NativeRecorder>,
    mut recorder: ResMut<Recorder>,
    mut closes: MessageReader<WindowCloseRequested>,
    mut exit: MessageWriter<AppExit>,
    mut redraw: MessageWriter<RequestRedraw>,
    mut windows: Query<(Entity, &mut Window), With<PrimaryWindow>>,
) {
    for close in closes.read() {
        if windows.iter().any(|(entity, _)| entity == close.window) {
            recorder.quit();
        }
    }
    if CTRL_C.swap(false, Ordering::SeqCst) {
        recorder.quit();
    }
    native.frames = native.frames.saturating_add(1);
    if !native.started && native.frames >= 3 && !windows.is_empty() {
        native.started = true;
        // Quitting before the recording starts never starts it, nor reserves its directory.
        if let Some(config) = native.config.as_ref().filter(|_| !recorder.quit_requested) {
            match RecordingSession::start(config) {
                Ok(session) => {
                    native.session = Some(session);
                    recorder.state = Some(RecordingState::Starting);
                }
                Err(e) => {
                    error!("Recording failed: {e}");
                    recorder.state = Some(RecordingState::Failed(e));
                }
            }
        }
    }
    if let Some(session) = &mut native.session {
        // ⌘Q, the Dock's Quit or logout, refused natively until the MP4 is finalized.
        if session.take_quit_request() {
            recorder.quit();
        }
        if recorder.stop_requested {
            session.stop();
        }
        let next = session.poll().clone();
        if recorder.state.as_ref() != Some(&next) {
            info!("Recorder: {next:?}");
            recorder.state = Some(next);
        }
    }
    if let Some(config) = &native.config {
        let label = match &recorder.state {
            Some(RecordingState::Starting) => "Preparing recording",
            Some(RecordingState::Recording) => "REC",
            Some(RecordingState::Stopping) => "Finalizing recording",
            Some(RecordingState::Finished) => "Recording saved",
            Some(RecordingState::Failed(_)) => "Recording FAILED",
            None => "",
        };
        if native.started {
            for (_, mut window) in &mut windows {
                let title = format!("{} — {label}", config.window_title);
                if window.title != title {
                    window.title = title;
                }
            }
        }
    }
    if recorder.quit_requested
        && (recorder
            .state
            .as_ref()
            .is_none_or(RecordingState::is_terminal))
    {
        exit.write(AppExit::Success);
    }
    // Polling must not wait for input in a reactive update mode.
    if matches!(
        recorder.state,
        Some(RecordingState::Starting | RecordingState::Stopping)
    ) {
        redraw.write(RequestRedraw);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard, PoisonError};

    /// `CTRL_C` is one flag for the whole process: tests that update an app take turns.
    fn one_at_a_time() -> MutexGuard<'static, ()> {
        static LOCK: Mutex<()> = Mutex::new(());
        LOCK.lock().unwrap_or_else(PoisonError::into_inner)
    }
    fn app(config: Option<RecordingConfig>) -> App {
        let mut app = App::new();
        app.add_plugins(MinimalPlugins)
            .add_plugins(WindowPlugin {
                close_when_requested: false,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .add_plugins(RecorderPlugin(config));
        app
    }
    #[test]
    fn disabled_recorder_never_starts_capture_and_quits_normally() {
        let _turn = one_at_a_time();
        let mut app = app(None);
        for _ in 0..4 {
            app.update();
        }
        assert!(app.world().resource::<Recorder>().state.is_none());
        assert!(app.world().non_send::<NativeRecorder>().session.is_none());
        app.world_mut().resource_mut::<Recorder>().quit();
        app.update();
        assert!(app.should_exit().is_some());
    }
    #[test]
    fn quit_waits_for_terminal_recording_state() {
        let _turn = one_at_a_time();
        let mut app = app(None);
        {
            let mut recorder = app.world_mut().resource_mut::<Recorder>();
            recorder.state = Some(RecordingState::Stopping);
            recorder.quit();
        }
        app.update();
        assert!(app.should_exit().is_none());
        app.world_mut().resource_mut::<Recorder>().state = Some(RecordingState::Finished);
        app.update();
        assert!(app.should_exit().is_some());
    }
    #[test]
    fn ctrl_c_quits_through_the_recorder() {
        let _turn = one_at_a_time();
        let mut app = app(None);
        app.update();
        app.world_mut().resource_mut::<Recorder>().state = Some(RecordingState::Recording);
        CTRL_C.store(true, Ordering::SeqCst);
        app.update();
        assert!(!CTRL_C.load(Ordering::SeqCst), "taken");
        assert!(app.world().resource::<Recorder>().quit_requested);
        assert!(app.should_exit().is_none(), "waits for the MP4");
    }
    #[test]
    fn quitting_before_the_start_never_starts_a_recording() {
        let _turn = one_at_a_time();
        let output =
            std::env::temp_dir().join(format!("bgr-early-quit-{}.mp4", std::process::id()));
        let mut app = app(Some(RecordingConfig::new(&output, "Game")));
        app.world_mut().spawn((Window::default(), PrimaryWindow));
        app.world_mut().resource_mut::<Recorder>().quit();
        for _ in 0..4 {
            app.update();
        }
        assert!(app.world().resource::<Recorder>().state.is_none());
        assert!(app.world().non_send::<NativeRecorder>().session.is_none());
        let mut staging = output.into_os_string();
        staging.push(".recording");
        assert!(!std::path::Path::new(&staging).exists());
        assert!(app.should_exit().is_some());
    }
    #[test]
    fn polling_asks_for_frames_while_starting_or_stopping() {
        let _turn = one_at_a_time();
        #[derive(Resource, Default)]
        struct Asked(usize);
        let mut app = app(None);
        app.init_resource::<Asked>().add_systems(
            PostUpdate,
            |mut asked: MessageReader<RequestRedraw>, mut count: ResMut<Asked>| {
                count.0 = asked.read().count();
            },
        );
        let frames_asked = |app: &mut App, state| {
            app.world_mut().resource_mut::<Recorder>().state = state;
            app.update();
            app.world().resource::<Asked>().0
        };
        assert_eq!(frames_asked(&mut app, Some(RecordingState::Starting)), 1);
        assert_eq!(frames_asked(&mut app, Some(RecordingState::Recording)), 0);
        assert_eq!(frames_asked(&mut app, Some(RecordingState::Stopping)), 1);
        assert_eq!(frames_asked(&mut app, Some(RecordingState::Finished)), 0);
        assert_eq!(frames_asked(&mut app, None), 0);
    }
    #[test]
    #[should_panic(expected = "close_when_requested=false")]
    fn rejects_lifecycle_that_would_destroy_window_before_finalization() {
        let mut app = App::new();
        app.add_plugins(WindowPlugin::default())
            .add_plugins(RecorderPlugin(None));
    }
    #[test]
    #[should_panic(expected = "disable TerminalCtrlCHandlerPlugin")]
    fn rejects_bevys_ctrl_c_handler_which_exits_before_finalization() {
        let mut app = App::new();
        app.add_plugins(TerminalCtrlCHandlerPlugin)
            .add_plugins(WindowPlugin {
                close_when_requested: false,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .add_plugins(RecorderPlugin(None));
    }
}
