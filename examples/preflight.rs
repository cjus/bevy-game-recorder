fn main() {
    println!(
        "Screen recording permission already available: {}",
        bevy_game_recorder::RecordingSession::permission_available()
    );
}
