pub const PlaybackState = enum {
    stopped,
    playing,
    paused,
    buffering,
};

pub const VideoBackendStatus = enum {
    software,
    interop_handle,
    true_zero_copy,
    force_zero_copy_blocked,
};

pub const VideoFallbackReason = enum {
    none,
    unsupported_mode,
    backend_failure,
    import_failure,
    format_not_supported,
};

pub const Snapshot = struct {
    state: PlaybackState = .stopped,
    current_time: f64 = 0.0,
    duration: f64 = 0.0,
    volume: f64 = 1.0,
    playback_speed: f64 = 1.0,
    has_media: bool = false,
    video_backend_status: VideoBackendStatus = .software,
    video_fallback_reason: VideoFallbackReason = .none,
};

pub fn stateLabel(state: PlaybackState) []const u8 {
    return switch (state) {
        .stopped => "stopped",
        .playing => "playing",
        .paused => "paused",
        .buffering => "buffering",
    };
}
