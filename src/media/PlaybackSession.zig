const std = @import("std");
const Snapshot = @import("../engine/Snapshot.zig").Snapshot;
const Player = @import("Player.zig").Player;
const AudioOutput = @import("../audio/AudioOutput.zig").AudioOutput;
const VideoPipeline = @import("../video/VideoPipeline.zig").VideoPipeline;
const VideoFrame = VideoPipeline.VideoFrame;

pub const PlaybackSession = struct {
    allocator: std.mem.Allocator,
    player: Player = .{},
    audio_output: AudioOutput = .{},
    video_pipeline: VideoPipeline = .{},

    pub fn init(allocator: std.mem.Allocator) PlaybackSession {
        return PlaybackSession{
            .allocator = allocator,
        };
    }

    pub fn start(self: *PlaybackSession) !void {
        try self.player.init();
    }

    pub fn stop(self: *PlaybackSession) void {
        self.destroyOutputs();
        self.player.deinit();
    }

    pub fn openMedia(self: *PlaybackSession, path: []const u8) void {
        self.destroyOutputs();

        self.player.open(path) catch return;

        self.video_pipeline.init(&self.player) catch return;

        self.audio_output.init(&self.player) catch {
            self.destroyOutputs();
            return;
        };

        if (!self.player.play()) {
            self.destroyOutputs();
            return;
        }

        self.audio_output.start() catch {
            self.destroyOutputs();
            return;
        };

        self.audio_output.setVolume(self.player.volume());
        self.audio_output.setSpeed(self.player.playbackSpeed());

        self.video_pipeline.start() catch {
            self.destroyOutputs();
            return;
        };
    }

    pub fn play(self: *PlaybackSession) void {
        _ = self.player.play();
    }

    pub fn pause(self: *PlaybackSession) void {
        _ = self.player.pause();
    }

    pub fn stopPlayback(self: *PlaybackSession) void {
        _ = self.player.stopPlayback();
    }

    pub fn seek(self: *PlaybackSession, time: f64) void {
        self.player.seek(time);
    }

    pub fn setVolume(self: *PlaybackSession, volume: f64) void {
        self.player.setVolume(volume);
    }

    pub fn setSpeed(self: *PlaybackSession, speed: f64) void {
        self.player.setSpeed(speed);
    }

    pub fn tick(self: *PlaybackSession) void {
        var state = self.player.state();

        self.audio_output.setPaused(state != .playing);

        if (self.player.isSeekPending()) {
            if (self.player.applySeek()) {
                self.audio_output.reset();
                state = self.player.state();
                self.audio_output.setPaused(state != .playing);
                self.video_pipeline.reset();
            }
        }

        if (state == .playing and self.video_pipeline.initialized) {
            if (self.audio_output.masterClock()) |master_clock| {
                self.player.setCurrentTime(master_clock);
            } else if (!self.player.hasAudio()) {
                self.player.setCurrentTime(self.player.videoPts());
            }
        }

        self.audio_output.setVolume(self.player.volume());
        self.audio_output.setSpeed(self.player.playbackSpeed());
        self.player.clampCurrentTimeToDuration();
    }

    pub fn snapshot(self: *PlaybackSession) Snapshot {
        return Snapshot{
            .state = self.player.state(),
            .current_time = self.player.currentTime(),
            .duration = self.player.duration(),
            .volume = self.player.volume(),
            .playback_speed = self.player.playbackSpeed(),
            .has_media = self.player.hasMedia(),
        };
    }

    pub fn getFrameForRender(self: *PlaybackSession, master_clock: f64) ?VideoFrame {
        return self.video_pipeline.getFrameForRender(master_clock);
    }

    fn destroyOutputs(self: *PlaybackSession) void {
        self.video_pipeline.destroy();
        self.audio_output.destroy();
    }
};
