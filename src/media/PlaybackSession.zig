const std = @import("std");
const c = @import("../ffi/cplayer.zig").c;
const Snapshot = @import("../engine/Snapshot.zig").Snapshot;
const VideoBackendStatus = @import("../engine/Snapshot.zig").VideoBackendStatus;
const VideoFallbackReason = @import("../engine/Snapshot.zig").VideoFallbackReason;
const VideoHwBackend = @import("../engine/Snapshot.zig").VideoHwBackend;
const VideoHwPolicy = @import("../engine/Snapshot.zig").VideoHwPolicy;
const Player = @import("Player.zig").Player;
const AudioOutput = @import("../audio/AudioOutput.zig").AudioOutput;
const VideoPipeline = @import("../video/VideoPipeline.zig").VideoPipeline;
const RenderFrame = VideoPipeline.RenderFrame;

fn clearTextField(field: *[32]u8) void {
    field.* = [_]u8{0} ** 32;
}

fn setTextField(field: *[32]u8, text: []const u8) void {
    clearTextField(field);
    if (text.len == 0) {
        return;
    }

    const n = @min(text.len, field.len - 1);
    @memcpy(field[0..n], text[0..n]);
}

fn setTextFieldFromC(field: *[32]u8, c_text: [*c]const u8) void {
    if (c_text == null) {
        clearTextField(field);
        return;
    }

    setTextField(field, std.mem.span(c_text));
}

fn bitrateKbps(value: i64) i32 {
    if (value <= 0) {
        return 0;
    }

    const kbps = @divTrunc(value, 1000);
    return std.math.cast(i32, kbps) orelse std.math.maxInt(i32);
}

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
        const interop_status: VideoBackendStatus = switch (self.video_pipeline.interopStatus()) {
            .software => .software,
            .interop_handle => .interop_handle,
            .true_zero_copy => .true_zero_copy,
            .force_zero_copy_blocked => .force_zero_copy_blocked,
        };

        const fallback_reason: VideoFallbackReason = switch (self.video_pipeline.interopFallbackReason()) {
            .none => .none,
            .unsupported_mode => .unsupported_mode,
            .backend_failure => .backend_failure,
            .import_failure => .import_failure,
            .format_not_supported => .format_not_supported,
        };

        const hw_backend: VideoHwBackend = switch (self.player.videoHwBackend()) {
            c.VIDEO_HW_BACKEND_VIDEOTOOLBOX => .videotoolbox,
            c.VIDEO_HW_BACKEND_D3D11VA => .d3d11va,
            c.VIDEO_HW_BACKEND_DXVA2 => .dxva2,
            else => .none,
        };

        const hw_policy: VideoHwPolicy = switch (self.player.videoHwPolicy()) {
            c.VIDEO_HW_POLICY_OFF => .off,
            c.VIDEO_HW_POLICY_D3D11VA => .d3d11va,
            c.VIDEO_HW_POLICY_DXVA2 => .dxva2,
            c.VIDEO_HW_POLICY_VIDEOTOOLBOX => .videotoolbox,
            else => .auto,
        };

        var media_format: [32]u8 = [_]u8{0} ** 32;
        var video_codec: [32]u8 = [_]u8{0} ** 32;
        var audio_codec: [32]u8 = [_]u8{0} ** 32;

        var media_bitrate_kbps: i32 = 0;
        var video_bitrate_kbps: i32 = 0;
        var audio_bitrate_kbps: i32 = 0;
        var video_fps_num: i32 = 0;
        var video_fps_den: i32 = 0;
        var audio_sample_rate: i32 = 0;
        var audio_channels: i32 = 0;

        const raw = self.player.raw();
        if (raw.demuxer.fmt_ctx != null) {
            const fmt_ctx = raw.demuxer.fmt_ctx;
            if (fmt_ctx.*.iformat != null) {
                setTextFieldFromC(&media_format, fmt_ctx.*.iformat.*.name);
            }
            media_bitrate_kbps = bitrateKbps(fmt_ctx.*.bit_rate);
        }

        if (raw.decoder.codec_ctx != null) {
            const codec_ctx = raw.decoder.codec_ctx;
            if (codec_ctx.*.codec != null and codec_ctx.*.codec.*.name != null) {
                setTextFieldFromC(&video_codec, codec_ctx.*.codec.*.name);
            }
            video_bitrate_kbps = bitrateKbps(codec_ctx.*.bit_rate);
        }

        if (raw.demuxer.video_stream != null) {
            const rate = raw.demuxer.video_stream.*.avg_frame_rate;
            video_fps_num = rate.num;
            video_fps_den = rate.den;
        }

        if (raw.has_audio != 0 and raw.audio_decoder.codec_ctx != null) {
            const ac = raw.audio_decoder.codec_ctx;
            if (ac.*.codec != null and ac.*.codec.*.name != null) {
                setTextFieldFromC(&audio_codec, ac.*.codec.*.name);
            }
            audio_bitrate_kbps = bitrateKbps(ac.*.bit_rate);
            audio_sample_rate = raw.audio_decoder.sample_rate;
            audio_channels = raw.audio_decoder.channels;
        }

        return Snapshot{
            .state = self.player.state(),
            .current_time = self.player.currentTime(),
            .duration = self.player.duration(),
            .volume = self.player.volume(),
            .playback_speed = self.player.playbackSpeed(),
            .has_media = self.player.hasMedia(),
            .video_backend_status = interop_status,
            .video_fallback_reason = fallback_reason,
            .video_hw_enabled = self.player.isVideoHwEnabled(),
            .video_hw_backend = hw_backend,
            .video_hw_policy = hw_policy,
            .media_format = media_format,
            .media_bitrate_kbps = media_bitrate_kbps,
            .video_codec = video_codec,
            .video_bitrate_kbps = video_bitrate_kbps,
            .video_fps_num = video_fps_num,
            .video_fps_den = video_fps_den,
            .audio_codec = audio_codec,
            .audio_bitrate_kbps = audio_bitrate_kbps,
            .audio_sample_rate = audio_sample_rate,
            .audio_channels = audio_channels,
        };
    }

    pub fn getFrameForRender(self: *PlaybackSession, master_clock: f64) ?RenderFrame {
        return self.video_pipeline.getFrameForRender(master_clock);
    }

    pub fn reportTrueZeroCopySubmitResult(self: *PlaybackSession, success: bool) void {
        self.video_pipeline.reportTrueZeroCopySubmitResult(success);
    }

    pub fn setTrueZeroCopyActive(self: *PlaybackSession, active: bool) void {
        self.video_pipeline.setTrueZeroCopyActive(active);
    }

    fn destroyOutputs(self: *PlaybackSession) void {
        self.player.stopDemuxer();
        self.video_pipeline.destroy();
        self.audio_output.destroy();
    }
};
