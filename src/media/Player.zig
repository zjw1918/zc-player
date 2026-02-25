const std = @import("std");
const c = @import("../ffi/cplayer.zig").c;
const SnapshotMod = @import("../engine/Snapshot.zig");
const PlaybackState = SnapshotMod.PlaybackState;

pub const Player = struct {
    const max_path_len: usize = 1024;

    handle: c.Player = undefined,
    initialized: bool = false,

    pub const VideoPlanes = struct {
        planes: [4][*c]u8,
        linesizes: [4]c_int,
        plane_count: c_int,
    };

    pub fn init(self: *Player) !void {
        if (self.initialized) {
            return error.AlreadyInitialized;
        }

        if (c.player_init(&self.handle) != 0) {
            return error.InitFailed;
        }

        self.initialized = true;
    }

    pub fn deinit(self: *Player) void {
        if (!self.initialized) {
            return;
        }

        c.player_destroy(&self.handle);
        self.initialized = false;
    }

    pub fn open(self: *Player, path: []const u8) !void {
        var path_buf: [max_path_len]u8 = [_]u8{0} ** max_path_len;
        const n = @min(path.len, path_buf.len - 1);
        @memcpy(path_buf[0..n], path[0..n]);
        path_buf[n] = 0;

        if (c.player_open(&self.handle, &path_buf[0]) != 0) {
            return error.OpenFailed;
        }
    }

    pub fn play(self: *Player) bool {
        return c.player_command(&self.handle, c.PLAYER_COMMAND_PLAY) == 0;
    }

    pub fn pause(self: *Player) bool {
        return c.player_command(&self.handle, c.PLAYER_COMMAND_PAUSE) == 0;
    }

    pub fn stopPlayback(self: *Player) bool {
        return c.player_command(&self.handle, c.PLAYER_COMMAND_STOP) == 0;
    }

    pub fn seek(self: *Player, time: f64) void {
        c.player_seek(&self.handle, time);
    }

    pub fn setVolume(self: *Player, volume_value: f64) void {
        c.player_set_volume(&self.handle, volume_value);
    }

    pub fn setSpeed(self: *Player, speed: f64) void {
        c.player_set_playback_speed(&self.handle, speed);
    }

    pub fn state(self: *Player) PlaybackState {
        return mapState(c.player_get_state(&self.handle));
    }

    pub fn hasMedia(self: *Player) bool {
        return c.player_has_media_loaded(&self.handle) != 0;
    }

    pub fn hasAudio(self: *Player) bool {
        return c.player_has_audio(&self.handle) != 0;
    }

    pub fn playbackSpeed(self: *Player) f64 {
        return c.player_get_playback_speed(&self.handle);
    }

    pub fn currentTime(self: *Player) f64 {
        return self.handle.current_time;
    }

    pub fn duration(self: *Player) f64 {
        return self.handle.duration;
    }

    pub fn volume(self: *Player) f64 {
        return self.handle.volume;
    }

    pub fn isSeekPending(self: *Player) bool {
        return self.handle.seek_pending != 0;
    }

    pub fn applySeek(self: *Player) bool {
        return c.player_apply_seek(&self.handle) == 0;
    }

    pub fn stopDemuxer(self: *Player) void {
        c.player_stop_demuxer(&self.handle);
    }

    pub fn setCurrentTime(self: *Player, time: f64) void {
        self.handle.current_time = time;
    }

    pub fn videoPts(self: *Player) f64 {
        return c.player_get_video_pts(&self.handle);
    }

    pub fn videoFormat(self: *Player) c_int {
        return c.player_get_video_format(&self.handle);
    }

    pub fn isVideoHwEnabled(self: *Player) bool {
        return c.player_is_video_hw_enabled(&self.handle) != 0;
    }

    pub fn videoHwBackend(self: *Player) c_int {
        return c.player_get_video_hw_backend(&self.handle);
    }

    pub fn videoHwPolicy(self: *Player) c_int {
        return c.player_get_video_hw_policy(&self.handle);
    }

    pub fn videoPlanes(self: *Player) ?VideoPlanes {
        var planes: [4][*c]u8 = .{ null, null, null, null };
        var linesizes: [4]c_int = .{ 0, 0, 0, 0 };
        var plane_count: c_int = 0;

        if (c.player_get_video_planes(&self.handle, &planes, &linesizes, &plane_count) != 0) {
            return null;
        }

        return VideoPlanes{
            .planes = planes,
            .linesizes = linesizes,
            .plane_count = plane_count,
        };
    }

    pub fn clampCurrentTimeToDuration(self: *Player) void {
        if (self.handle.duration > 0.0 and self.handle.current_time > self.handle.duration) {
            self.handle.current_time = self.handle.duration;
        }
    }

    pub fn raw(self: *Player) *c.Player {
        return &self.handle;
    }

    fn mapState(player_state: c.PlayerState) PlaybackState {
        return switch (player_state) {
            c.PLAYER_STATE_STOPPED => .stopped,
            c.PLAYER_STATE_PLAYING => .playing,
            c.PLAYER_STATE_PAUSED => .paused,
            c.PLAYER_STATE_BUFFERING => .buffering,
            else => .stopped,
        };
    }
};
