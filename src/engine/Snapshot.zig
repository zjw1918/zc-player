pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
    buffering,
};

pub const Snapshot = struct {
    state: PlaybackState = .stopped,
    current_time: f64 = 0.0,
    duration: f64 = 0.0,
    volume: f64 = 1.0,
    playback_speed: f64 = 1.0,
    has_media: bool = false,
};

pub fn stateLabel(state: PlaybackState) []const u8 {
    return switch (state) {
        .stopped => "stopped",
        .playing => "playing",
        .paused => "paused",
        .buffering => "buffering",
    };
}
