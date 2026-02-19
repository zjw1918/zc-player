const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("video/video_pipeline.h");
});

const PLAYING_STATE = switch (@typeInfo(c.PlayerState)) {
    .@"enum" => @as(c.PlayerState, @enumFromInt(c.PLAYER_STATE_PLAYING)),
    else => @as(c.PlayerState, @intCast(c.PLAYER_STATE_PLAYING))
};

fn frameCapacity() c_int {
    return c.VIDEO_FRAME_QUEUE_CAPACITY;
}

fn queuePushLocked(pipeline: *c.VideoPipeline, src_data: [*c]u8, src_linesize: c_int, width: c_int, height: c_int, pts: f64) c_int {
    if (pipeline.count >= frameCapacity()) {
        return -1;
    }

    const row_size: usize = @as(usize, @intCast(width)) * 4;
    if (src_linesize < @as(c_int, @intCast(row_size))) {
        return -1;
    }

    const tail_idx: usize = @intCast(pipeline.tail);
    const frame = &pipeline.frames[tail_idx];

    if (frame.width != width or frame.height != height or frame.linesize < @as(c_int, @intCast(row_size))) {
        return -1;
    }

    if (frame.data == null or src_data == null) {
        return -1;
    }

    const dst_base: [*]u8 = @ptrCast(frame.data);
    const src_base: [*]const u8 = @ptrCast(src_data);
    const src_stride: usize = @intCast(src_linesize);
    const dst_stride: usize = @intCast(frame.linesize);

    var y: c_int = 0;
    while (y < height) : (y += 1) {
        const y_usize: usize = @intCast(y);
        const dst_off = y_usize * dst_stride;
        const src_off = y_usize * src_stride;
        std.mem.copyForwards(u8, dst_base[dst_off .. dst_off + row_size], src_base[src_off .. src_off + row_size]);
    }

    frame.pts = pts;
    pipeline.tail = @mod(pipeline.tail + 1, frameCapacity());
    pipeline.count += 1;
    return 0;
}

fn queuePopToUploadLocked(pipeline: *c.VideoPipeline) c_int {
    if (pipeline.count == 0) {
        return -1;
    }

    const head_idx: usize = @intCast(pipeline.head);
    const frame = &pipeline.frames[head_idx];

    if (frame.data == null or pipeline.upload_buffer == null) {
        return -1;
    }

    const frame_size: usize = @as(usize, @intCast(frame.linesize)) * @as(usize, @intCast(frame.height));
    if (pipeline.upload_buffer_size < frame_size) {
        return -1;
    }

    const dst: [*]u8 = @ptrCast(pipeline.upload_buffer);
    const src: [*]const u8 = @ptrCast(frame.data);
    std.mem.copyForwards(u8, dst[0..frame_size], src[0..frame_size]);

    pipeline.pending_width = frame.width;
    pipeline.pending_height = frame.height;
    pipeline.pending_linesize = frame.linesize;
    pipeline.pending_pts = frame.pts;
    pipeline.have_pending_upload = 1;

    pipeline.head = @mod(pipeline.head + 1, frameCapacity());
    pipeline.count -= 1;
    if (pipeline.can_push != null) {
        _ = c.SDL_SignalCondition(pipeline.can_push);
    }
    return 0;
}

fn fallbackVideoClock(pipeline: *c.VideoPipeline, frame_pts: f64) f64 {
    const now_ns = c.SDL_GetTicksNS();

    if (pipeline.clock_base_pts < 0.0 or frame_pts < pipeline.clock_base_pts) {
        pipeline.clock_base_pts = frame_pts;
        pipeline.clock_base_time_ns = now_ns;
    }

    const elapsed_ns = now_ns - pipeline.clock_base_time_ns;
    var elapsed_seconds = @as(f64, @floatFromInt(elapsed_ns)) / 1000000000.0;
    elapsed_seconds *= c.player_get_playback_speed(pipeline.player);
    return pipeline.clock_base_pts + elapsed_seconds;
}

fn decodeThreadMain(userdata: ?*anyopaque) callconv(.c) c_int {
    if (userdata == null) {
        return -1;
    }

    const pipeline: *c.VideoPipeline = @ptrCast(@alignCast(userdata.?));

    while (true) {
        if (pipeline.queue_mutex == null) {
            break;
        }

        _ = c.SDL_LockMutex(pipeline.queue_mutex);
        while (pipeline.decode_running != 0 and pipeline.count >= frameCapacity()) {
            _ = c.SDL_WaitCondition(pipeline.can_push, pipeline.queue_mutex);
        }
        var running = pipeline.decode_running;
        _ = c.SDL_UnlockMutex(pipeline.queue_mutex);

        if (running == 0) {
            break;
        }

        if (c.player_get_state(pipeline.player) != PLAYING_STATE) {
            c.SDL_Delay(2);
            continue;
        }

        if (c.player_decode_frame(pipeline.player) != 0) {
            c.SDL_Delay(1);
            continue;
        }

        var data: [*c]u8 = null;
        var linesize: c_int = 0;
        if (c.player_get_video_frame(pipeline.player, &data, &linesize) != 0) {
            c.SDL_Delay(1);
            continue;
        }

        const pts = c.player_get_video_pts(pipeline.player);

        _ = c.SDL_LockMutex(pipeline.queue_mutex);
        if (pipeline.decode_running != 0) {
            if (pipeline.pts_offset_valid == 0) {
                pipeline.pts_offset = pts - pipeline.expected_start_pts;
                pipeline.pts_offset_valid = 1;
            }

            const adjusted_pts = pts - pipeline.pts_offset;
            if (queuePushLocked(pipeline, data, linesize, pipeline.player.*.width, pipeline.player.*.height, adjusted_pts) != 0) {
                _ = c.SDL_UnlockMutex(pipeline.queue_mutex);
                c.SDL_Delay(1);
                continue;
            }
        }

        running = pipeline.decode_running;
        _ = c.SDL_UnlockMutex(pipeline.queue_mutex);

        if (running == 0) {
            break;
        }
    }

    return 0;
}

pub export fn video_pipeline_init(pipeline: ?*c.VideoPipeline, player: ?*c.Player) c_int {
    if (pipeline == null or player == null) {
        return -1;
    }

    const p = pipeline.?;
    const pl = player.?;

    p.* = std.mem.zeroes(c.VideoPipeline);
    p.player = pl;
    p.clock_base_pts = -1.0;
    p.expected_start_pts = pl.current_time;

    const width = pl.width;
    const height = pl.height;
    if (width <= 0 or height <= 0) {
        return -1;
    }

    p.queue_mutex = c.SDL_CreateMutex();
    if (p.queue_mutex == null) {
        return -1;
    }

    p.can_push = c.SDL_CreateCondition();
    if (p.can_push == null) {
        c.SDL_DestroyMutex(p.queue_mutex);
        p.queue_mutex = null;
        return -1;
    }

    const frame_size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const linesize: c_int = width * 4;

    var i: c_int = 0;
    while (i < frameCapacity()) : (i += 1) {
        const idx: usize = @intCast(i);
        p.frames[idx].data = @ptrCast(c.malloc(frame_size));
        if (p.frames[idx].data == null) {
            video_pipeline_destroy(p);
            return -1;
        }

        p.frames[idx].width = width;
        p.frames[idx].height = height;
        p.frames[idx].linesize = linesize;
        p.frames[idx].pts = 0.0;
    }

    p.upload_buffer = @ptrCast(c.malloc(frame_size));
    if (p.upload_buffer == null) {
        video_pipeline_destroy(p);
        return -1;
    }

    p.upload_buffer_size = frame_size;
    return 0;
}

pub export fn video_pipeline_start(pipeline: ?*c.VideoPipeline) c_int {
    if (pipeline == null) {
        return -1;
    }

    const p = pipeline.?;

    if (p.decode_thread != null) {
        return 0;
    }

    p.decode_running = 1;
    p.decode_thread = c.SDL_CreateThread(decodeThreadMain, "video_decode", p);
    if (p.decode_thread == null) {
        p.decode_running = 0;
        return -1;
    }

    return 0;
}

pub export fn video_pipeline_stop(pipeline: ?*c.VideoPipeline) void {
    if (pipeline == null) {
        return;
    }

    const p = pipeline.?;

    if (p.decode_thread == null or p.queue_mutex == null) {
        return;
    }

    _ = c.SDL_LockMutex(p.queue_mutex);
    p.decode_running = 0;
    if (p.can_push != null) {
        _ = c.SDL_BroadcastCondition(p.can_push);
    }
    _ = c.SDL_UnlockMutex(p.queue_mutex);

    c.SDL_WaitThread(p.decode_thread, null);
    p.decode_thread = null;
}

pub export fn video_pipeline_reset(pipeline: ?*c.VideoPipeline) void {
    if (pipeline == null or pipeline.?.queue_mutex == null) {
        return;
    }

    const p = pipeline.?;

    _ = c.SDL_LockMutex(p.queue_mutex);
    p.head = 0;
    p.tail = 0;
    p.count = 0;
    p.have_pending_upload = 0;
    p.pending_width = 0;
    p.pending_height = 0;
    p.pending_linesize = 0;
    p.pending_pts = 0.0;
    p.clock_base_pts = -1.0;
    p.clock_base_time_ns = 0;
    p.expected_start_pts = if (p.player != null) p.player.*.current_time else 0.0;
    p.pts_offset_valid = 0;
    p.pts_offset = 0.0;
    if (p.can_push != null) {
        _ = c.SDL_BroadcastCondition(p.can_push);
    }
    _ = c.SDL_UnlockMutex(p.queue_mutex);
}

pub export fn video_pipeline_destroy(pipeline: ?*c.VideoPipeline) void {
    if (pipeline == null) {
        return;
    }

    const p = pipeline.?;

    video_pipeline_stop(p);

    if (p.upload_buffer != null) {
        c.free(p.upload_buffer);
        p.upload_buffer = null;
        p.upload_buffer_size = 0;
    }

    var i: c_int = 0;
    while (i < frameCapacity()) : (i += 1) {
        const idx: usize = @intCast(i);
        if (p.frames[idx].data != null) {
            c.free(p.frames[idx].data);
            p.frames[idx].data = null;
        }
    }

    if (p.can_push != null) {
        c.SDL_DestroyCondition(p.can_push);
        p.can_push = null;
    }

    if (p.queue_mutex != null) {
        c.SDL_DestroyMutex(p.queue_mutex);
        p.queue_mutex = null;
    }

    p.head = 0;
    p.tail = 0;
    p.count = 0;
    p.decode_running = 0;
    p.have_pending_upload = 0;
    p.clock_base_pts = -1.0;
    p.clock_base_time_ns = 0;
    p.expected_start_pts = 0.0;
    p.pts_offset_valid = 0;
    p.pts_offset = 0.0;
}

pub export fn video_pipeline_get_frame_for_render(
    pipeline: ?*c.VideoPipeline,
    master_clock: f64,
    data: [*c][*c]u8,
    width: [*c]c_int,
    height: [*c]c_int,
    linesize: [*c]c_int,
) c_int {
    if (pipeline == null or data == null or width == null or height == null or linesize == null) {
        return -1;
    }

    const p = pipeline.?;

    if (p.have_pending_upload == 0) {
        if (p.queue_mutex != null) {
            _ = c.SDL_LockMutex(p.queue_mutex);
            if (p.count > 0) {
                _ = queuePopToUploadLocked(p);
            }
            _ = c.SDL_UnlockMutex(p.queue_mutex);
        }
    }

    if (p.have_pending_upload == 0) {
        return 0;
    }

    var render_clock = master_clock;
    if (render_clock < 0.0) {
        render_clock = fallbackVideoClock(p, p.pending_pts);
    }

    const frame_delay = p.pending_pts - render_clock;
    if (frame_delay <= 0.002) {
        data.* = p.upload_buffer;
        width.* = p.pending_width;
        height.* = p.pending_height;
        linesize.* = p.pending_linesize;
        p.have_pending_upload = 0;
        return 1;
    }

    return 0;
}
