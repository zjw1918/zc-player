const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("player/player.h");
});

fn stateFromInt(value: c_int) c.PlayerState {
    return switch (@typeInfo(c.PlayerState)) {
        .@"enum" => @enumFromInt(value),
        else => @as(c.PlayerState, @intCast(value)),
    };
}

fn stateToInt(value: c.PlayerState) c_int {
    return switch (@typeInfo(c.PlayerState)) {
        .@"enum" => @as(c_int, @intCast(@intFromEnum(value))),
        else => @as(c_int, @intCast(value)),
    };
}

fn commandFromInt(value: c_int) c.PlayerCommand {
    return switch (@typeInfo(c.PlayerCommand)) {
        .@"enum" => @enumFromInt(value),
        else => @as(c.PlayerCommand, @intCast(value)),
    };
}

const STATE_STOPPED = stateFromInt(c.PLAYER_STATE_STOPPED);
const STATE_PLAYING = stateFromInt(c.PLAYER_STATE_PLAYING);
const STATE_PAUSED = stateFromInt(c.PLAYER_STATE_PAUSED);
const STATE_BUFFERING = stateFromInt(c.PLAYER_STATE_BUFFERING);

const CMD_PLAY = commandFromInt(c.PLAYER_COMMAND_PLAY);
const CMD_PAUSE = commandFromInt(c.PLAYER_COMMAND_PAUSE);
const CMD_STOP = commandFromInt(c.PLAYER_COMMAND_STOP);
const CMD_TOGGLE_PLAY_PAUSE = commandFromInt(c.PLAYER_COMMAND_TOGGLE_PLAY_PAUSE);

fn normalizeState(value: c_int) c.PlayerState {
    return switch (value) {
        c.PLAYER_STATE_PLAYING => STATE_PLAYING,
        c.PLAYER_STATE_PAUSED => STATE_PAUSED,
        c.PLAYER_STATE_BUFFERING => STATE_BUFFERING,
        else => STATE_STOPPED,
    };
}

fn hasMediaInternal(player: ?*const c.Player) bool {
    if (player == null) {
        return false;
    }

    const p = player.?;
    return p.demuxer.fmt_ctx != null and p.width > 0 and p.height > 0;
}

fn setState(player: ?*c.Player, state: c.PlayerState) void {
    if (player == null) {
        return;
    }

    const p = player.?;
    p.state = state;
    _ = c.SDL_SetAtomicInt(&p.state_atomic, stateToInt(state));
}

fn canTransition(player: ?*c.Player, from: c.PlayerState, to: c.PlayerState) bool {
    if (player == null) {
        return false;
    }

    if (to != STATE_STOPPED and !hasMediaInternal(player)) {
        return false;
    }

    return switch (from) {
        STATE_STOPPED => to == STATE_STOPPED or to == STATE_PLAYING,
        STATE_PLAYING => to == STATE_PLAYING or to == STATE_PAUSED or to == STATE_STOPPED or to == STATE_BUFFERING,
        STATE_PAUSED => to == STATE_PAUSED or to == STATE_PLAYING or to == STATE_STOPPED or to == STATE_BUFFERING,
        STATE_BUFFERING => to == STATE_BUFFERING or to == STATE_PLAYING or to == STATE_PAUSED or to == STATE_STOPPED,
        else => false,
    };
}

fn transition(player: ?*c.Player, to: c.PlayerState) c_int {
    if (player == null) {
        return -1;
    }

    const p = player.?;
    const from = player_get_state(player);
    if (!canTransition(player, from, to)) {
        return -1;
    }

    if (to == STATE_STOPPED) {
        p.current_time = 0.0;
        p.eof = 0;
        p.seek_pending = 1;
        p.seek_target = 0.0;
    } else if (to == STATE_PLAYING) {
        p.eof = 0;
    }

    if (from != to) {
        setState(player, to);
    }

    return 0;
}

fn closeMedia(player: *c.Player) void {
    c.video_decoder_destroy(&player.decoder);

    if (player.has_audio != 0) {
        c.audio_decoder_destroy(&player.audio_decoder);
    }

    c.demuxer_close(&player.demuxer);

    player.has_audio = 0;
    player.width = 0;
    player.height = 0;
}

pub export fn player_init(player: ?*c.Player) c_int {
    if (player == null) {
        return -1;
    }

    const p = player.?;
    p.* = std.mem.zeroes(c.Player);

    p.video_decode_mutex = c.SDL_CreateMutex();
    if (p.video_decode_mutex == null) {
        return -1;
    }

    p.audio_decode_mutex = c.SDL_CreateMutex();
    if (p.audio_decode_mutex == null) {
        c.SDL_DestroyMutex(p.video_decode_mutex);
        p.video_decode_mutex = null;
        return -1;
    }

    setState(player, STATE_STOPPED);
    p.volume = 1.0;
    p.playback_speed = 1.0;
    return 0;
}

pub export fn player_destroy(player: ?*c.Player) void {
    if (player == null) {
        return;
    }

    const p = player.?;

    closeMedia(p);

    if (p.filepath != null) {
        c.free(p.filepath);
        p.filepath = null;
    }

    if (p.video_decode_mutex != null) {
        c.SDL_DestroyMutex(p.video_decode_mutex);
        p.video_decode_mutex = null;
    }

    if (p.audio_decode_mutex != null) {
        c.SDL_DestroyMutex(p.audio_decode_mutex);
        p.audio_decode_mutex = null;
    }
}

pub export fn player_open(player: ?*c.Player, filepath: [*c]const u8) c_int {
    if (player == null or filepath == null) {
        return -1;
    }

    const p = player.?;

    closeMedia(p);

    if (p.filepath != null) {
        c.free(p.filepath);
        p.filepath = null;
    }

    p.filepath = c.strdup(filepath);
    if (p.filepath == null) {
        return -1;
    }

    if (c.demuxer_open(&p.demuxer, filepath) != 0) {
        closeMedia(p);
        setState(player, STATE_STOPPED);
        return -1;
    }

    if (c.video_decoder_init(&p.decoder, p.demuxer.video_stream) != 0) {
        closeMedia(p);
        setState(player, STATE_STOPPED);
        return -1;
    }

    p.width = p.decoder.width;
    p.height = p.decoder.height;

    if (p.demuxer.audio_stream != null and c.audio_decoder_init(&p.audio_decoder, p.demuxer.audio_stream) == 0) {
        p.has_audio = 1;
    } else {
        p.has_audio = 0;
    }

    if (c.demuxer_start(&p.demuxer) != 0) {
        closeMedia(p);
        setState(player, STATE_STOPPED);
        return -1;
    }

    setState(player, STATE_STOPPED);
    p.current_time = 0.0;

    if (p.demuxer.fmt_ctx != null and p.demuxer.fmt_ctx.*.duration > 0) {
        p.duration = @as(f64, @floatFromInt(p.demuxer.fmt_ctx.*.duration)) / @as(f64, @floatFromInt(c.AV_TIME_BASE));
    } else {
        p.duration = 0.0;
    }

    p.eof = 0;
    p.seek_pending = 0;
    p.seek_target = 0.0;

    return 0;
}

pub export fn player_command(player: ?*c.Player, command: c.PlayerCommand) c_int {
    if (player == null) {
        return -1;
    }

    return switch (command) {
        CMD_PLAY => transition(player, STATE_PLAYING),
        CMD_PAUSE => transition(player, STATE_PAUSED),
        CMD_STOP => transition(player, STATE_STOPPED),
        CMD_TOGGLE_PLAY_PAUSE => blk: {
            if (player_get_state(player) == STATE_PLAYING) {
                break :blk transition(player, STATE_PAUSED);
            }
            break :blk transition(player, STATE_PLAYING);
        },
        else => -1,
    };
}

pub export fn player_get_state(player: ?*c.Player) c.PlayerState {
    if (player == null) {
        return STATE_STOPPED;
    }

    return normalizeState(c.SDL_GetAtomicInt(&player.?.state_atomic));
}

pub export fn player_has_media_loaded(player: ?*c.Player) c_int {
    return if (hasMediaInternal(player)) 1 else 0;
}

pub export fn player_play(player: ?*c.Player) void {
    _ = player_command(player, CMD_PLAY);
}

pub export fn player_pause(player: ?*c.Player) void {
    _ = player_command(player, CMD_PAUSE);
}

pub export fn player_stop(player: ?*c.Player) void {
    _ = player_command(player, CMD_STOP);
}

pub export fn player_seek(player: ?*c.Player, time: f64) void {
    if (player == null) {
        return;
    }

    var target = time;
    const p = player.?;

    if (target < 0.0) {
        target = 0.0;
    }

    if (p.duration > 0.0 and target > p.duration) {
        target = p.duration;
    }

    p.seek_pending = 1;
    p.seek_target = target;
}

pub export fn player_apply_seek(player: ?*c.Player) c_int {
    if (player == null or player.?.seek_pending == 0) {
        return 0;
    }

    const p = player.?;

    if (p.video_decode_mutex != null) {
        _ = c.SDL_LockMutex(p.video_decode_mutex);
    }

    if (p.audio_decode_mutex != null) {
        _ = c.SDL_LockMutex(p.audio_decode_mutex);
    }

    const target = p.seek_target;
    var result: c_int = -1;

    if (c.demuxer_seek(&p.demuxer, target) == 0) {
        c.video_decoder_flush(&p.decoder);
        p.decoder.pts = target;

        if (p.has_audio != 0) {
            c.audio_decoder_flush(&p.audio_decoder);
            p.audio_decoder.pts = target;
        }

        p.current_time = target;
        p.eof = 0;
        p.seek_pending = 0;
        result = 0;
    } else {
        p.seek_pending = 0;
    }

    if (p.audio_decode_mutex != null) {
        _ = c.SDL_UnlockMutex(p.audio_decode_mutex);
    }

    if (p.video_decode_mutex != null) {
        _ = c.SDL_UnlockMutex(p.video_decode_mutex);
    }

    return result;
}

pub export fn player_set_volume(player: ?*c.Player, volume: f64) void {
    if (player == null) {
        return;
    }

    var clamped = volume;
    if (clamped > 1.0) {
        clamped = 1.0;
    }

    if (clamped < 0.0) {
        clamped = 0.0;
    }

    player.?.volume = clamped;
}

pub export fn player_set_playback_speed(player: ?*c.Player, speed: f64) void {
    if (player == null) {
        return;
    }

    var clamped = speed;

    if (clamped < 0.25) {
        clamped = 0.25;
    }

    if (clamped > 2.0) {
        clamped = 2.0;
    }

    player.?.playback_speed = clamped;
}

pub export fn player_get_playback_speed(player: ?*c.Player) f64 {
    if (player == null) {
        return 1.0;
    }

    if (player.?.playback_speed <= 0.0) {
        return 1.0;
    }

    return player.?.playback_speed;
}

pub export fn player_get_time(player: ?*c.Player) f64 {
    if (player == null) {
        return 0.0;
    }
    return player.?.current_time;
}

pub export fn player_decode_frame(player: ?*c.Player) c_int {
    if (player == null) {
        return -1;
    }

    const p = player.?;

    if (player_get_state(player) != STATE_PLAYING) {
        return -1;
    }

    if (p.video_decode_mutex != null) {
        _ = c.SDL_LockMutex(p.video_decode_mutex);
    }

    const ret = c.video_decoder_decode_frame(&p.decoder, &p.demuxer);

    if (p.video_decode_mutex != null) {
        _ = c.SDL_UnlockMutex(p.video_decode_mutex);
    }

    return ret;
}

pub export fn player_get_video_frame(player: ?*c.Player, data: [*c][*c]u8, linesize: [*c]c_int) c_int {
    if (player == null or data == null or linesize == null) {
        return -1;
    }

    return c.video_decoder_get_image(&player.?.decoder, data, linesize);
}

pub export fn player_get_video_format(player: ?*c.Player) c_int {
    if (player == null) {
        return c.VIDEO_FRAME_FORMAT_RGBA;
    }

    return c.video_decoder_get_format(&player.?.decoder);
}

pub export fn player_get_video_pts(player: ?*c.Player) f64 {
    if (player == null) {
        return 0.0;
    }
    return player.?.decoder.pts;
}

pub export fn player_has_audio(player: ?*c.Player) c_int {
    if (player == null) {
        return 0;
    }
    return player.?.has_audio;
}

pub export fn player_get_audio_sample_rate(player: ?*c.Player) c_int {
    if (player == null or player.?.has_audio == 0) {
        return 0;
    }

    return player.?.audio_decoder.sample_rate;
}

pub export fn player_get_audio_channels(player: ?*c.Player) c_int {
    if (player == null or player.?.has_audio == 0) {
        return 0;
    }

    return player.?.audio_decoder.channels;
}

pub export fn player_decode_audio(player: ?*c.Player) c_int {
    if (player == null) {
        return -1;
    }

    const p = player.?;

    if (p.has_audio == 0) {
        return -1;
    }

    if (player_get_state(player) != STATE_PLAYING) {
        return -1;
    }

    if (p.audio_decode_mutex != null) {
        _ = c.SDL_LockMutex(p.audio_decode_mutex);
    }

    const ret = c.audio_decoder_decode_frame(&p.audio_decoder, &p.demuxer);

    if (p.audio_decode_mutex != null) {
        _ = c.SDL_UnlockMutex(p.audio_decode_mutex);
    }

    return ret;
}

pub export fn player_get_audio_samples(player: ?*c.Player, data: [*c][*c]u8, nb_samples: [*c]c_int) c_int {
    if (player == null or player.?.has_audio == 0 or data == null or nb_samples == null) {
        return -1;
    }

    return c.audio_decoder_get_samples(&player.?.audio_decoder, data, nb_samples);
}

pub export fn player_get_audio_pts(player: ?*c.Player) f64 {
    if (player == null or player.?.has_audio == 0) {
        return 0.0;
    }

    return player.?.audio_decoder.pts;
}

pub export fn player_stop_demuxer(player: ?*c.Player) void {
    if (player == null) {
        return;
    }

    c.demuxer_stop(&player.?.demuxer);
}
