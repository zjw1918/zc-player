const std = @import("std");
const c = @cImport({
    @cInclude("player/demuxer.h");
});

fn capacity() c_int {
    return c.DEMUXER_PACKET_QUEUE_CAPACITY;
}

fn queueClear(queue: *c.DemuxerPacketQueue) void {
    while (queue.count > 0) {
        const head_idx: usize = @intCast(queue.head);
        const packet = queue.packets[head_idx];
        queue.packets[head_idx] = null;
        queue.head = @mod(queue.head + 1, capacity());
        queue.count -= 1;

        if (packet != null) {
            var packet_copy = packet;
            c.av_packet_free(&packet_copy);
        }
    }

    queue.head = 0;
    queue.tail = 0;
}

fn queuePush(queue: *c.DemuxerPacketQueue, src_packet: *const c.AVPacket) c_int {
    if (queue.count >= capacity()) {
        return -1;
    }

    const packet = c.av_packet_alloc();
    if (packet == null) {
        return -1;
    }

    if (c.av_packet_ref(packet, src_packet) < 0) {
        var packet_copy = packet;
        c.av_packet_free(&packet_copy);
        return -1;
    }

    const tail_idx: usize = @intCast(queue.tail);
    queue.packets[tail_idx] = packet;
    queue.tail = @mod(queue.tail + 1, capacity());
    queue.count += 1;
    return 0;
}

fn queuePop(queue: *c.DemuxerPacketQueue, dst_packet: *c.AVPacket) c_int {
    if (queue.count <= 0) {
        return -1;
    }

    const head_idx: usize = @intCast(queue.head);
    const packet = queue.packets[head_idx];
    queue.packets[head_idx] = null;
    queue.head = @mod(queue.head + 1, capacity());
    queue.count -= 1;

    if (packet == null) {
        return -1;
    }

    c.av_packet_move_ref(dst_packet, packet);
    var packet_copy = packet;
    c.av_packet_free(&packet_copy);
    return 0;
}

fn demuxThreadMain(userdata: ?*anyopaque) callconv(.c) c_int {
    if (userdata == null) {
        return -1;
    }

    const demuxer: *c.Demuxer = @ptrCast(@alignCast(userdata.?));

    const packet = c.av_packet_alloc();
    if (packet == null) {
        if (demuxer.mutex != null) {
            _ = c.SDL_LockMutex(demuxer.mutex);
            demuxer.eof = 1;
            demuxer.thread_running = 0;
            if (demuxer.can_read_video != null) {
                _ = c.SDL_BroadcastCondition(demuxer.can_read_video);
            }
            if (demuxer.can_read_audio != null) {
                _ = c.SDL_BroadcastCondition(demuxer.can_read_audio);
            }
            if (demuxer.can_write != null) {
                _ = c.SDL_BroadcastCondition(demuxer.can_write);
            }
            _ = c.SDL_UnlockMutex(demuxer.mutex);
        }
        return -1;
    }

    while (true) {
        _ = c.SDL_LockMutex(demuxer.mutex);
        const stop_requested = demuxer.stop_requested;
        _ = c.SDL_UnlockMutex(demuxer.mutex);
        if (stop_requested != 0) {
            break;
        }

        const ret = c.av_read_frame(demuxer.fmt_ctx, packet);
        if (ret < 0) {
            _ = c.SDL_LockMutex(demuxer.mutex);
            demuxer.eof = 1;
            if (demuxer.can_read_video != null) {
                _ = c.SDL_BroadcastCondition(demuxer.can_read_video);
            }
            if (demuxer.can_read_audio != null) {
                _ = c.SDL_BroadcastCondition(demuxer.can_read_audio);
            }
            if (demuxer.can_write != null) {
                _ = c.SDL_BroadcastCondition(demuxer.can_write);
            }
            _ = c.SDL_UnlockMutex(demuxer.mutex);
            break;
        }

        _ = c.SDL_LockMutex(demuxer.mutex);

        var queue: ?*c.DemuxerPacketQueue = null;
        var can_read: ?*c.SDL_Condition = null;

        if (packet.*.stream_index == demuxer.video_stream_index) {
            queue = &demuxer.video_queue;
            can_read = demuxer.can_read_video;
        } else if (packet.*.stream_index == demuxer.audio_stream_index) {
            queue = &demuxer.audio_queue;
            can_read = demuxer.can_read_audio;
        }

        while (queue != null and demuxer.stop_requested == 0 and queue.?.count >= capacity()) {
            _ = c.SDL_WaitCondition(demuxer.can_write, demuxer.mutex);
        }

        if (queue != null and demuxer.stop_requested == 0) {
            if (queuePush(queue.?, packet) != 0) {
                demuxer.stop_requested = 1;
                demuxer.eof = 1;
                if (demuxer.can_read_video != null) {
                    _ = c.SDL_BroadcastCondition(demuxer.can_read_video);
                }
                if (demuxer.can_read_audio != null) {
                    _ = c.SDL_BroadcastCondition(demuxer.can_read_audio);
                }
                if (demuxer.can_write != null) {
                    _ = c.SDL_BroadcastCondition(demuxer.can_write);
                }
            } else if (can_read != null) {
                _ = c.SDL_SignalCondition(can_read);
            }
        }

        const should_stop = demuxer.stop_requested;
        _ = c.SDL_UnlockMutex(demuxer.mutex);

        c.av_packet_unref(packet);

        if (should_stop != 0) {
            break;
        }
    }

    var packet_copy = packet;
    c.av_packet_free(&packet_copy);

    _ = c.SDL_LockMutex(demuxer.mutex);
    demuxer.thread_running = 0;
    if (demuxer.can_read_video != null) {
        _ = c.SDL_BroadcastCondition(demuxer.can_read_video);
    }
    if (demuxer.can_read_audio != null) {
        _ = c.SDL_BroadcastCondition(demuxer.can_read_audio);
    }
    if (demuxer.can_write != null) {
        _ = c.SDL_BroadcastCondition(demuxer.can_write);
    }
    _ = c.SDL_UnlockMutex(demuxer.mutex);

    return 0;
}

pub export fn demuxer_open(demuxer: ?*c.Demuxer, filepath: [*c]const u8) c_int {
    if (demuxer == null or filepath == null) {
        return -1;
    }

    const d = demuxer.?;
    d.* = std.mem.zeroes(c.Demuxer);
    d.video_stream_index = -1;
    d.audio_stream_index = -1;

    if (c.avformat_open_input(&d.fmt_ctx, filepath, null, null) != 0) {
        demuxer_close(demuxer);
        return -1;
    }

    if (c.avformat_find_stream_info(d.fmt_ctx, null) < 0) {
        demuxer_close(demuxer);
        return -1;
    }

    var i: c_uint = 0;
    while (i < d.fmt_ctx.*.nb_streams) : (i += 1) {
        const stream = d.fmt_ctx.*.streams[i];
        if (stream == null) {
            continue;
        }

        if (stream.*.codecpar != null and stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_VIDEO and d.video_stream_index < 0) {
            d.video_stream_index = @intCast(i);
            d.video_stream = stream;
        }

        if (stream.*.codecpar != null and stream.*.codecpar.*.codec_type == c.AVMEDIA_TYPE_AUDIO and d.audio_stream_index < 0) {
            d.audio_stream_index = @intCast(i);
            d.audio_stream = stream;
        }
    }

    if (d.video_stream_index < 0 or d.video_stream == null) {
        demuxer_close(demuxer);
        return -1;
    }

    d.mutex = c.SDL_CreateMutex();
    if (d.mutex == null) {
        demuxer_close(demuxer);
        return -1;
    }

    d.can_read_video = c.SDL_CreateCondition();
    if (d.can_read_video == null) {
        demuxer_close(demuxer);
        return -1;
    }

    d.can_read_audio = c.SDL_CreateCondition();
    if (d.can_read_audio == null) {
        demuxer_close(demuxer);
        return -1;
    }

    d.can_write = c.SDL_CreateCondition();
    if (d.can_write == null) {
        demuxer_close(demuxer);
        return -1;
    }

    return 0;
}

pub export fn demuxer_start(demuxer: ?*c.Demuxer) c_int {
    if (demuxer == null) {
        return -1;
    }

    const d = demuxer.?;
    if (d.fmt_ctx == null or d.mutex == null) {
        return -1;
    }

    if (d.thread != null) {
        return 0;
    }

    _ = c.SDL_LockMutex(d.mutex);
    d.stop_requested = 0;
    d.eof = 0;
    d.thread_running = 1;
    _ = c.SDL_UnlockMutex(d.mutex);

    d.thread = c.SDL_CreateThread(demuxThreadMain, "demux", d);
    if (d.thread == null) {
        _ = c.SDL_LockMutex(d.mutex);
        d.thread_running = 0;
        _ = c.SDL_UnlockMutex(d.mutex);
        return -1;
    }

    return 0;
}

pub export fn demuxer_stop(demuxer: ?*c.Demuxer) void {
    if (demuxer == null) {
        return;
    }

    const d = demuxer.?;

    if (d.mutex != null) {
        _ = c.SDL_LockMutex(d.mutex);
        d.stop_requested = 1;
        if (d.can_read_video != null) {
            _ = c.SDL_BroadcastCondition(d.can_read_video);
        }
        if (d.can_read_audio != null) {
            _ = c.SDL_BroadcastCondition(d.can_read_audio);
        }
        if (d.can_write != null) {
            _ = c.SDL_BroadcastCondition(d.can_write);
        }
        _ = c.SDL_UnlockMutex(d.mutex);
    }

    if (d.thread != null) {
        c.SDL_WaitThread(d.thread, null);
        d.thread = null;
    }

    if (d.mutex != null) {
        _ = c.SDL_LockMutex(d.mutex);
        d.thread_running = 0;
        _ = c.SDL_UnlockMutex(d.mutex);
    }
}

pub export fn demuxer_close(demuxer: ?*c.Demuxer) void {
    if (demuxer == null) {
        return;
    }

    const d = demuxer.?;

    demuxer_stop(demuxer);

    if (d.mutex != null) {
        _ = c.SDL_LockMutex(d.mutex);
        queueClear(&d.video_queue);
        queueClear(&d.audio_queue);
        _ = c.SDL_UnlockMutex(d.mutex);
    }

    if (d.can_write != null) {
        c.SDL_DestroyCondition(d.can_write);
        d.can_write = null;
    }

    if (d.can_read_audio != null) {
        c.SDL_DestroyCondition(d.can_read_audio);
        d.can_read_audio = null;
    }

    if (d.can_read_video != null) {
        c.SDL_DestroyCondition(d.can_read_video);
        d.can_read_video = null;
    }

    if (d.mutex != null) {
        c.SDL_DestroyMutex(d.mutex);
        d.mutex = null;
    }

    if (d.fmt_ctx != null) {
        c.avformat_close_input(&d.fmt_ctx);
    }

    d.video_stream_index = -1;
    d.audio_stream_index = -1;
    d.video_stream = null;
    d.audio_stream = null;
    d.thread_running = 0;
    d.stop_requested = 0;
    d.eof = 0;
}

pub export fn demuxer_seek(demuxer: ?*c.Demuxer, time_seconds: f64) c_int {
    if (demuxer == null) {
        return -1;
    }

    const d = demuxer.?;
    if (d.fmt_ctx == null or d.mutex == null) {
        return -1;
    }

    var target_seconds = time_seconds;
    if (target_seconds < 0.0) {
        target_seconds = 0.0;
    }

    demuxer_stop(demuxer);

    const target_ts: i64 = @intFromFloat(target_seconds * @as(f64, @floatFromInt(c.AV_TIME_BASE)));
    var seek_ret = c.avformat_seek_file(d.fmt_ctx, -1, std.math.minInt(i64), target_ts, std.math.maxInt(i64), c.AVSEEK_FLAG_BACKWARD);
    if (seek_ret < 0) {
        seek_ret = c.av_seek_frame(d.fmt_ctx, -1, target_ts, c.AVSEEK_FLAG_BACKWARD);
    }

    _ = c.SDL_LockMutex(d.mutex);
    queueClear(&d.video_queue);
    queueClear(&d.audio_queue);
    d.stop_requested = 0;
    d.eof = 0;
    _ = c.SDL_UnlockMutex(d.mutex);

    if (seek_ret < 0) {
        return -1;
    }

    _ = c.avformat_flush(d.fmt_ctx);
    return demuxer_start(demuxer);
}

fn demuxerPopPacket(demuxer: *c.Demuxer, queue: *c.DemuxerPacketQueue, can_read: ?*c.SDL_Condition, out_packet: [*c]c.AVPacket) c_int {
    if (can_read == null or out_packet == null or demuxer.mutex == null) {
        return -1;
    }

    c.av_packet_unref(out_packet);

    _ = c.SDL_LockMutex(demuxer.mutex);
    while (queue.count == 0 and demuxer.eof == 0 and demuxer.stop_requested == 0 and demuxer.thread_running != 0) {
        _ = c.SDL_WaitCondition(can_read, demuxer.mutex);
    }

    if (queue.count > 0) {
        _ = queuePop(queue, out_packet);
        if (demuxer.can_write != null) {
            _ = c.SDL_SignalCondition(demuxer.can_write);
        }
        _ = c.SDL_UnlockMutex(demuxer.mutex);
        return 1;
    }

    const stop_requested = demuxer.stop_requested;
    const eof = demuxer.eof;
    _ = c.SDL_UnlockMutex(demuxer.mutex);

    if (stop_requested != 0) {
        return -1;
    }

    if (eof != 0) {
        return 0;
    }

    return -1;
}

pub export fn demuxer_pop_video_packet(demuxer: ?*c.Demuxer, out_packet: [*c]c.AVPacket) c_int {
    if (demuxer == null or out_packet == null) {
        return -1;
    }

    const d = demuxer.?;
    return demuxerPopPacket(d, &d.video_queue, d.can_read_video, out_packet);
}

pub export fn demuxer_pop_audio_packet(demuxer: ?*c.Demuxer, out_packet: [*c]c.AVPacket) c_int {
    if (demuxer == null or out_packet == null) {
        return -1;
    }

    const d = demuxer.?;
    if (d.audio_stream_index < 0 or d.audio_stream == null) {
        return 0;
    }

    return demuxerPopPacket(d, &d.audio_queue, d.can_read_audio, out_packet);
}

pub export fn demuxer_is_eof(demuxer: ?*c.Demuxer) c_int {
    if (demuxer == null or demuxer.?.mutex == null) {
        return 1;
    }

    const d = demuxer.?;
    _ = c.SDL_LockMutex(d.mutex);
    const eof = d.eof;
    _ = c.SDL_UnlockMutex(d.mutex);
    return eof;
}
