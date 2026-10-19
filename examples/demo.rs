use bevy::{audio::PlaybackSettings, prelude::*, window::ExitCondition};
use bevy_game_recorder::{Recorder, RecorderPlugin, RecordingConfig};
const TITLE: &str = "Bevy Game Recorder Demo";
#[derive(Component)]
struct Moving;
#[derive(Component)]
struct Status;
fn main() {
    let mut args = std::env::args().skip(1);
    let mut recording = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--record" if recording.is_none() => {
                recording = Some(RecordingConfig::new(
                    args.next().expect("--record requires an output.mp4 path"),
                    TITLE,
                ))
            }
            "--help" => {
                println!(
                    "demo [--record output.mp4]\nSpace: stop and save. Escape/window close: save and quit.\nA quiet test tone plays to verify application audio."
                );
                return;
            }
            _ => panic!("Unknown or repeated argument: {arg}; use --help"),
        }
    }
    App::new()
        .add_plugins(DefaultPlugins.set(WindowPlugin {
            primary_window: Some(Window {
                title: TITLE.into(),
                resolution: (1280, 720).into(),
                ..default()
            }),
            close_when_requested: false,
            exit_condition: ExitCondition::DontExit,
            ..default()
        }))
        .add_plugins(RecorderPlugin(recording))
        .add_systems(Startup, setup)
        .add_systems(Update, animate)
        .run();
}
fn setup(mut commands: Commands, assets: Res<AssetServer>) {
    commands.spawn(Camera2d);
    commands.spawn((
        Sprite::from_color(Color::srgb(0.1, 0.7, 0.9), Vec2::new(140., 140.)),
        Moving,
    ));
    commands.spawn((
        Text::new("Recorder demo"),
        TextFont {
            font_size: FontSize::Px(26.),
            ..default()
        },
        Node {
            position_type: PositionType::Absolute,
            top: px(20),
            left: px(20),
            ..default()
        },
        Status,
    ));
    commands.spawn((
        AudioPlayer::new(assets.load("tone.wav")),
        PlaybackSettings::LOOP,
    ));
}
fn animate(
    time: Res<Time>,
    keys: Res<ButtonInput<KeyCode>>,
    mut recorder: ResMut<Recorder>,
    mut sprites: Query<&mut Transform, With<Moving>>,
    mut text: Query<&mut Text, With<Status>>,
) {
    if keys.just_pressed(KeyCode::Space) {
        recorder.stop();
    }
    if keys.just_pressed(KeyCode::Escape) {
        recorder.quit();
    }
    for mut transform in &mut sprites {
        transform.translation.x = time.elapsed_secs().sin() * 350.;
        transform.rotation = Quat::from_rotation_z(time.elapsed_secs());
    }
    for mut text in &mut text {
        **text = format!(
            "BEVY GAME RECORDER | {:.1}s\n{}\nSpace: save   Esc: save and quit",
            time.elapsed_secs(),
            recorder
                .state
                .as_ref()
                .map_or("Recording OFF".into(), |s| format!("{s:?}"))
        );
    }
}
