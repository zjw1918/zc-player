const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("audio/audio_output.h");
});

const PLAYING_STATE = switch (@typeInfo(c.PlayerState)) {
    .@"enum" => @as(c.PlayerState, @enumFromInt(c.PLAYER_STATE_PLAYING)),
    else => @as(c.PlayerState, @intCast(c.PLAYER_STATE_PLAYING))
};

const AUDIO_RING_MIN_SIZE: usize = 32768;
const AUDIO_CALLBACK_CHUNK_BYTES: usize = 4096;
const AUDIO_RING_SIZE_SECONDS: usize = 1;
const AUDIO_RING_TARGET_NUM: usize = 3;
const AUDIO_RING_TARGET_DEN: usize = 4;
const AUDIO_RING_RESUME_NUM: usize = 1;
const AUDIO_RING_RESUME_DEN: usize = 2;

fn ringReadLocked(output: *c.AudioOutput, dst: [*]u8, len: usize) usize {
    if (output.ring_used == 0 or len == 0 or output.ring_data == null) {
        return 0;
    }

    var to_read = len;
    if (to_read > output.ring_used) {
        to_read = output.ring_used;
    }

    var first = output.ring_size - output.ring_read_pos;
    if (first > to_read) {
        first = to_read;
    }

    const ring: [*]const u8 = @ptrCast(output.ring_data);
    std.mem.copyForwards(u8, dst[0..first], ring[output.ring_read_pos .. output.ring_read_pos + first]);

    const second = to_read - first;
    if (second > 0) {
        std.mem.copyForwards(u8, dst[first .. first + second], ring[0..second]);
    }

    output.ring_read_pos = @mod(output.ring_read_pos + to_read, output.ring_size);
    output.ring_used -= to_read;
    return to_read;
}

fn ringWriteLocked(output: *c.AudioOutput, src: [*]const u8, len: usize) void {
    if (len == 0 or output.ring_data == null) {
        return;
    }

    var first = output.ring_size - output.ring_write_pos;
    if (first > len) {
        first = len;
    }

    const ring: [*]u8 = @ptrCast(output.ring_data);
    std.mem.copyForwards(u8, ring[output.ring_write_pos .. output.ring_write_pos + first], src[0..first]);

    const second = len - first;
    if (second > 0) {
        std.mem.copyForwards(u8, ring[0..second], src[first .. first + second]);
    }

    output.ring_write_pos = @mod(output.ring_write_pos + len, output.ring_size);
    output.ring_used += len;
}

fn audioDecodeThreadMain(userdata: ?*anyopaque) callconv(.c) c_int {
    if (userdata == null) {
        return -1;
    }

    const output: *c.AudioOutput = @ptrCast(@alignCast(userdata.?));
    var decode_throttled: c_int = 0;

    while (true) {
        if (output.ring_mutex == null) {
            break;
        }

        _ = c.SDL_LockMutex(output.ring_mutex);
        var running = output.decode_running;
        _ = c.SDL_UnlockMutex(output.ring_mutex);

        if (running == 0) {
            break;
        }

        if (c.player_get_state(output.player) != PLAYING_STATE) {
            c.SDL_Delay(2);
            continue;
        }

        var stream_queued = c.SDL_GetAudioStreamQueued(output.stream);
        if (stream_queued < 0) {
            stream_queued = 0;
        }

        var should_decode: c_int = 1;
        _ = c.SDL_LockMutex(output.ring_mutex);
        const buffered = output.ring_used + @as(usize, @intCast(stream_queued));
        if (output.ring_target_bytes > 0) {
            if (decode_throttled != 0) {
                if (buffered > output.ring_resume_bytes) {
                    should_decode = 0;
                } else {
                    decode_throttled = 0;
                }
            } else if (buffered >= output.ring_target_bytes) {
                decode_throttled = 1;
                should_decode = 0;
            }
        }
        _ = c.SDL_UnlockMutex(output.ring_mutex);

        if (should_decode == 0) {
            c.SDL_Delay(1);
            continue;
        }

        if (c.player_decode_audio(output.player) != 0) {
            c.SDL_Delay(1);
            continue;
        }

        var samples: [*c]u8 = null;
        var nb_samples: c_int = 0;
        if (c.player_get_audio_samples(output.player, &samples, &nb_samples) != 0) {
            c.SDL_Delay(1);
            continue;
        }

        var bytes_remaining: c_int = nb_samples * output.bytes_per_frame;
        if (bytes_remaining <= 0 or samples == null) {
            continue;
        }

        var src: [*]const u8 = @ptrCast(samples);

        const pts = c.player_get_audio_pts(output.player);
        var frame_duration: f64 = 0.0;
        if (output.sample_rate > 0 and nb_samples > 0) {
            frame_duration = @as(f64, @floatFromInt(nb_samples)) / @as(f64, @floatFromInt(output.sample_rate));
        }

        _ = c.SDL_LockMutex(output.ring_mutex);

        if (output.decode_running != 0 and output.clock_base_pts < 0.0 and pts >= 0.0) {
            if (output.pts_offset_valid == 0) {
                output.pts_offset = pts - output.expected_start_pts;
                output.pts_offset_valid = 1;
            }
            const adjusted_pts = pts - output.pts_offset;
            output.clock_base_pts = adjusted_pts;
            output.clock_base_time_ns = c.SDL_GetTicksNS();
        }

        if (output.decode_running != 0 and frame_duration > 0.0) {
            var frame_start = output.expected_start_pts;
            if (pts >= 0.0) {
                if (output.pts_offset_valid == 0) {
                    output.pts_offset = pts - output.expected_start_pts;
                    output.pts_offset_valid = 1;
                }
                frame_start = pts - output.pts_offset;
            }

            if (output.decoded_end_valid == 0) {
                output.decoded_end_pts = frame_start;
                output.decoded_end_valid = 1;
            } else if (frame_start < output.decoded_end_pts) {
                frame_start = output.decoded_end_pts;
            }

            output.decoded_end_pts = frame_start + frame_duration;
            output.clock_base_pts = output.decoded_end_pts;
        }

        while (output.decode_running != 0 and bytes_remaining > 0) {
            const writable = output.ring_size - output.ring_used;
            if (writable == 0) {
                _ = c.SDL_WaitCondition(output.can_write, output.ring_mutex);
                continue;
            }

            var chunk: usize = @intCast(bytes_remaining);
            if (chunk > writable) {
                chunk = writable;
            }

            ringWriteLocked(output, src, chunk);
            src += chunk;
            bytes_remaining -= @as(c_int, @intCast(chunk));
        }

        running = output.decode_running;
        _ = c.SDL_UnlockMutex(output.ring_mutex);

        if (running == 0) {
            break;
        }
    }

    return 0;
}

fn audioCallback(userdata: ?*anyopaque, stream: ?*c.SDL_AudioStream, additional_amount: c_int, total_amount: c_int) callconv(.c) void {
    _ = total_amount;

    if (userdata == null or stream == null or additional_amount <= 0) {
        return;
    }

    const output: *c.AudioOutput = @ptrCast(@alignCast(userdata.?));

    if (output.enabled == 0 or output.device_opened == 0 or c.player_get_state(output.player) != PLAYING_STATE) {
        return;
    }

    var chunk: [AUDIO_CALLBACK_CHUNK_BYTES]u8 = undefined;
    var remaining = additional_amount;

    while (remaining > 0) {
        var request = remaining;
        if (request > @as(c_int, @intCast(AUDIO_CALLBACK_CHUNK_BYTES))) {
            request = @intCast(AUDIO_CALLBACK_CHUNK_BYTES);
        }

        var got: c_int = 0;

        if (output.ring_mutex != null) {
            _ = c.SDL_LockMutex(output.ring_mutex);
            if (output.ring_used > 0) {
                got = @as(c_int, @intCast(ringReadLocked(output, chunk[0..].ptr, @intCast(request))));
                if (output.can_write != null) {
                    _ = c.SDL_SignalCondition(output.can_write);
                }
            }
            _ = c.SDL_UnlockMutex(output.ring_mutex);
        }

        if (got <= 0) {
            const request_usize: usize = @intCast(request);
            @memset(chunk[0..request_usize], 0);
            if (!c.SDL_PutAudioStreamData(stream, chunk[0..request_usize].ptr, request)) {
                break;
            }
            remaining -= request;
            continue;
        }

        if (!c.SDL_PutAudioStreamData(stream, chunk[0..@as(usize, @intCast(got))].ptr, got)) {
            break;
        }

        remaining -= got;
    }
}

pub export fn audio_output_init(output: ?*c.AudioOutput, player: ?*c.Player) c_int {
    if (output == null or player == null) {
        return -1;
    }

    const o = output.?;
    const p = player.?;

    o.* = std.mem.zeroes(c.AudioOutput);
    o.player = p;
    o.enabled = if (c.player_has_audio(p) != 0) 1 else 0;
    o.clock_base_pts = -1.0;
    o.playback_speed = c.player_get_playback_speed(p);
    o.expected_start_pts = p.current_time;

    if (o.enabled == 0) {
        return 0;
    }

    const channels = c.player_get_audio_channels(p);
    if (channels <= 0) {
        return -1;
    }

    o.sample_rate = c.player_get_audio_sample_rate(p);
    if (o.sample_rate <= 0) {
        o.sample_rate = 48000;
    }

    o.bytes_per_frame = channels * @as(c_int, @intCast(@sizeOf(f32)));
    return 0;
}

pub export fn audio_output_start(output: ?*c.AudioOutput) c_int {
    if (output == null) {
        return -1;
    }

    const o = output.?;

    if (o.enabled == 0) {
        return 0;
    }

    const sample_rate = o.sample_rate;
    const channels = c.player_get_audio_channels(o.player);

    const bytes_per_second = @as(usize, @intCast(sample_rate)) * @as(usize, @intCast(channels)) * @sizeOf(f32);
    var ring_size = bytes_per_second * AUDIO_RING_SIZE_SECONDS;
    if (ring_size < AUDIO_RING_MIN_SIZE) {
        ring_size = AUDIO_RING_MIN_SIZE;
    }

    o.ring_data = @ptrCast(c.malloc(ring_size));
    if (o.ring_data == null) {
        return -1;
    }

    o.ring_size = ring_size;
    o.ring_read_pos = 0;
    o.ring_write_pos = 0;
    o.ring_used = 0;
    o.ring_target_bytes = (ring_size * AUDIO_RING_TARGET_NUM) / AUDIO_RING_TARGET_DEN;

    const min_target = AUDIO_CALLBACK_CHUNK_BYTES * 4;
    if (o.ring_target_bytes < min_target) {
        o.ring_target_bytes = min_target;
    }

    if (o.ring_target_bytes > o.ring_size) {
        o.ring_target_bytes = o.ring_size;
    }

    o.ring_resume_bytes = (o.ring_target_bytes * AUDIO_RING_RESUME_NUM) / AUDIO_RING_RESUME_DEN;

    o.ring_mutex = c.SDL_CreateMutex();
    if (o.ring_mutex == null) {
        audio_output_destroy(o);
        return -1;
    }

    o.can_write = c.SDL_CreateCondition();
    if (o.can_write == null) {
        audio_output_destroy(o);
        return -1;
    }

    var spec = c.SDL_AudioSpec{
        .freq = sample_rate,
        .format = c.SDL_AUDIO_F32LE,
        .channels = @intCast(channels)
    };

    o.stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, audioCallback, o);
    if (o.stream == null) {
        _ = c.fprintf(c.stderr(), "Failed to open audio stream: %s\n", c.SDL_GetError());
        audio_output_destroy(o);
        return -1;
    }

    _ = c.SDL_SetAudioStreamGain(o.stream, @floatCast(o.player.*.volume));
    _ = c.SDL_SetAudioStreamFrequencyRatio(o.stream, @floatCast(o.playback_speed));

    o.decode_running = 1;
    o.decode_thread = c.SDL_CreateThread(audioDecodeThreadMain, "audio_decode", o);
    if (o.decode_thread == null) {
        o.decode_running = 0;
        audio_output_destroy(o);
        return -1;
    }

    o.device_opened = 1;
    o.paused = 0;
    o.pause_started_ns = 0;
    o.paused_total_ns = 0;
    o.pts_offset_valid = 0;
    o.pts_offset = 0.0;
    o.decoded_end_valid = 0;
    o.decoded_end_pts = 0.0;

    if (!c.SDL_ResumeAudioStreamDevice(o.stream)) {
        _ = c.fprintf(c.stderr(), "Failed to resume audio stream device: %s\n", c.SDL_GetError());
    }

    return 0;
}

pub export fn audio_output_reset(output: ?*c.AudioOutput) void {
    if (output == null or output.?.enabled == 0) {
        return;
    }

    const o = output.?;

    if (o.stream != null) {
        _ = c.SDL_ClearAudioStream(o.stream);
    }

    if (o.ring_mutex == null) {
        return;
    }

    _ = c.SDL_LockMutex(o.ring_mutex);
    o.ring_read_pos = 0;
    o.ring_write_pos = 0;
    o.ring_used = 0;
    o.clock_base_pts = -1.0;
    o.clock_base_time_ns = 0;
    o.expected_start_pts = if (o.player != null) o.player.*.current_time else 0.0;
    o.pts_offset_valid = 0;
    o.pts_offset = 0.0;
    o.decoded_end_valid = 0;
    o.decoded_end_pts = 0.0;
    o.pause_started_ns = 0;
    o.paused_total_ns = 0;
    o.paused = 0;
    if (o.can_write != null) {
        _ = c.SDL_BroadcastCondition(o.can_write);
    }
    _ = c.SDL_UnlockMutex(o.ring_mutex);

    if (o.stream != null) {
        if (!c.SDL_ResumeAudioStreamDevice(o.stream)) {
            _ = c.fprintf(c.stderr(), "Failed to resume audio stream device: %s\n", c.SDL_GetError());
        }
    }
}

pub export fn audio_output_set_volume(output: ?*c.AudioOutput, volume: f64) void {
    if (output == null or output.?.enabled == 0 or output.?.stream == null) {
        return;
    }

    const o = output.?;

    var value = volume;
    if (value < 0.0) {
        value = 0.0;
    }

    if (value > 1.0) {
        value = 1.0;
    }

    _ = c.SDL_SetAudioStreamGain(o.stream, @floatCast(value));
}

pub export fn audio_output_set_playback_speed(output: ?*c.AudioOutput, speed: f64) void {
    if (output == null or output.?.enabled == 0 or output.?.stream == null) {
        return;
    }

    const o = output.?;

    var value = speed;
    if (value < 0.25) {
        value = 0.25;
    }

    if (value > 2.0) {
        value = 2.0;
    }

    o.playback_speed = value;
    _ = c.SDL_SetAudioStreamFrequencyRatio(o.stream, @floatCast(o.playback_speed));
}

pub export fn audio_output_set_paused(output: ?*c.AudioOutput, paused: c_int) void {
    if (output == null or output.?.enabled == 0 or output.?.stream == null or output.?.ring_mutex == null) {
        return;
    }

    const o = output.?;

    const target_paused: c_int = if (paused != 0) 1 else 0;
    const now_ns = c.SDL_GetTicksNS();

    _ = c.SDL_LockMutex(o.ring_mutex);
    if (target_paused != 0 and o.paused == 0) {
        o.paused = 1;
        o.pause_started_ns = now_ns;
    } else if (target_paused == 0 and o.paused != 0) {
        if (o.pause_started_ns > 0 and now_ns > o.pause_started_ns) {
            o.paused_total_ns += now_ns - o.pause_started_ns;
        }
        o.paused = 0;
        o.pause_started_ns = 0;
    }
    _ = c.SDL_UnlockMutex(o.ring_mutex);

    const device_paused: c_int = if (c.SDL_AudioStreamDevicePaused(o.stream)) 1 else 0;
    if (target_paused != device_paused) {
        const ok = if (target_paused != 0) c.SDL_PauseAudioStreamDevice(o.stream) else c.SDL_ResumeAudioStreamDevice(o.stream);
        if (!ok) {
            if (target_paused != 0) {
                _ = c.fprintf(c.stderr(), "Failed to pause audio stream device: %s\n", c.SDL_GetError());
            } else {
                _ = c.fprintf(c.stderr(), "Failed to resume audio stream device: %s\n", c.SDL_GetError());
            }
        }
    }
}

pub export fn audio_output_destroy(output: ?*c.AudioOutput) void {
    if (output == null) {
        return;
    }

    const o = output.?;

    if (o.decode_thread != null and o.ring_mutex != null) {
        _ = c.SDL_LockMutex(o.ring_mutex);
        o.decode_running = 0;
        if (o.can_write != null) {
            _ = c.SDL_BroadcastCondition(o.can_write);
        }
        _ = c.SDL_UnlockMutex(o.ring_mutex);

        c.SDL_WaitThread(o.decode_thread, null);
        o.decode_thread = null;
    }

    o.decode_running = 0;
    o.paused = 0;
    o.pause_started_ns = 0;
    o.paused_total_ns = 0;
    o.sample_rate = 0;
    o.playback_speed = 1.0;

    if (o.stream != null) {
        c.SDL_DestroyAudioStream(o.stream);
        o.stream = null;
    }

    if (o.can_write != null) {
        c.SDL_DestroyCondition(o.can_write);
        o.can_write = null;
    }

    if (o.ring_mutex != null) {
        c.SDL_DestroyMutex(o.ring_mutex);
        o.ring_mutex = null;
    }

    if (o.ring_data != null) {
        c.free(o.ring_data);
        o.ring_data = null;
    }

    o.ring_size = 0;
    o.ring_read_pos = 0;
    o.ring_write_pos = 0;
    o.ring_used = 0;
    o.ring_target_bytes = 0;
    o.ring_resume_bytes = 0;
    o.device_opened = 0;
    o.clock_base_pts = -1.0;
    o.clock_base_time_ns = 0;
    o.pts_offset_valid = 0;
    o.pts_offset = 0.0;
    o.decoded_end_valid = 0;
    o.decoded_end_pts = 0.0;
}

pub export fn audio_output_get_master_clock(output: ?*c.AudioOutput, out_clock: [*c]f64) c_int {
    if (output == null or out_clock == null or output.?.enabled == 0 or output.?.device_opened == 0 or output.?.ring_mutex == null) {
        return -1;
    }

    const o = output.?;

    _ = c.SDL_LockMutex(o.ring_mutex);
    if (o.decoded_end_valid == 0) {
        _ = c.SDL_UnlockMutex(o.ring_mutex);
        return -1;
    }

    const decoded_end_pts = o.decoded_end_pts;
    const expected_start_pts = o.expected_start_pts;
    const ring_used = o.ring_used;
    _ = c.SDL_UnlockMutex(o.ring_mutex);

    var stream_queued = c.SDL_GetAudioStreamQueued(o.stream);
    if (stream_queued < 0) {
        stream_queued = 0;
    }

    const buffered_bytes = @as(f64, @floatFromInt(stream_queued)) + @as(f64, @floatFromInt(ring_used));
    const bytes_per_second = @as(f64, @floatFromInt(o.bytes_per_frame)) * @as(f64, @floatFromInt(o.sample_rate));
    if (bytes_per_second <= 0.0) {
        return -1;
    }

    const buffered_seconds = buffered_bytes / bytes_per_second;
    out_clock.* = decoded_end_pts - buffered_seconds;

    if (out_clock.* < expected_start_pts) {
        out_clock.* = expected_start_pts;
    }

    return 0;
}
