use crate::{RecordingConfig, RecordingSession, RecordingState};
use bevy::{
    app::AppExit,
    prelude::*,
    window::{ExitCondition, PrimaryWindow, WindowCloseRequested, WindowPlugin},
};

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
fn drive_recorder(
    mut native: NonSendMut<NativeRecorder>,
    mut recorder: ResMut<Recorder>,
    mut closes: MessageReader<WindowCloseRequested>,
    mut exit: MessageWriter<AppExit>,
    mut windows: Query<(Entity, &mut Window), With<PrimaryWindow>>,
) {
    for close in closes.read() {
        if windows.iter().any(|(entity, _)| entity == close.window) {
            recorder.quit();
        }
    }
    native.frames = native.frames.saturating_add(1);
    if !native.started && native.frames >= 3 && !windows.is_empty() {
        native.started = true;
        if let Some(config) = &native.config {
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
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn disabled_recorder_never_starts_capture_and_quits_normally() {
        let mut app = App::new();
        app.add_plugins(MinimalPlugins)
            .add_plugins(WindowPlugin {
                close_when_requested: false,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .add_plugins(RecorderPlugin(None));
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
        let mut app = App::new();
        app.add_plugins(MinimalPlugins)
            .add_plugins(WindowPlugin {
                close_when_requested: false,
                exit_condition: ExitCondition::DontExit,
                ..default()
            })
            .add_plugins(RecorderPlugin(None));
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
    #[should_panic(expected = "close_when_requested=false")]
    fn rejects_lifecycle_that_would_destroy_window_before_finalization() {
        let mut app = App::new();
        app.add_plugins(WindowPlugin::default())
            .add_plugins(RecorderPlugin(None));
    }
}
