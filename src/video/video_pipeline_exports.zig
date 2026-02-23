const std = @import("std");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("libavutil/buffer.h");
    @cInclude("libavutil/frame.h");
    @cInclude("video/video_pipeline.h");
});

const PLAYING_STATE = switch (@typeInfo(c.PlayerState)) {
    .@"enum" => @as(c.PlayerState, @enumFromInt(c.PLAYER_STATE_PLAYING)),
    else => @as(c.PlayerState, @intCast(c.PLAYER_STATE_PLAYING)),
};

const render_late_drop_tolerance = 0.05;

fn frameCapacity() c_int {
    return c.VIDEO_FRAME_QUEUE_CAPACITY;
}

fn planeCountForFormat(format: c_int) c_int {
    return switch (format) {
        c.VIDEO_FRAME_FORMAT_YUV420P => 3,
        c.VIDEO_FRAME_FORMAT_NV12 => 2,
        else => 1,
    };
}

fn planeGeometry(format: c_int, width: c_int, height: c_int, plane_idx: c_int) ?struct { row_bytes: usize, rows: usize } {
    if (width <= 0 or height <= 0) {
        return null;
    }

    return switch (format) {
        c.VIDEO_FRAME_FORMAT_RGBA => if (plane_idx == 0)
            .{ .row_bytes = @as(usize, @intCast(width)) * 4, .rows = @as(usize, @intCast(height)) }
        else
            null,
        c.VIDEO_FRAME_FORMAT_NV12 => switch (plane_idx) {
            0 => .{ .row_bytes = @as(usize, @intCast(width)), .rows = @as(usize, @intCast(height)) },
            1 => .{ .row_bytes = @as(usize, @intCast(width)), .rows = @as(usize, @intCast(@divTrunc(height, 2))) },
            else => null,
        },
        c.VIDEO_FRAME_FORMAT_YUV420P => switch (plane_idx) {
            0 => .{ .row_bytes = @as(usize, @intCast(width)), .rows = @as(usize, @intCast(height)) },
            1, 2 => .{ .row_bytes = @as(usize, @intCast(@divTrunc(width, 2))), .rows = @as(usize, @intCast(@divTrunc(height, 2))) },
            else => null,
        },
        else => if (plane_idx == 0)
            .{ .row_bytes = @as(usize, @intCast(width)) * 4, .rows = @as(usize, @intCast(height)) }
        else
            null,
    };
}

fn decodeShouldSkipPlaneExtraction(true_zero_copy_active: c_int, source_hw: c_int, gpu_token: u64) bool {
    return true_zero_copy_active != 0 and source_hw != 0 and gpu_token != 0;
}

fn releaseGpuToken(token: *u64) void {
    if (token.* == 0) {
        return;
    }

    var frame: ?*c.AVFrame = @ptrFromInt(token.*);
    c.av_frame_free(&frame);
    token.* = 0;
}

fn retainGpuToken(token: u64) u64 {
    if (token == 0) {
        return 0;
    }

    const source: *c.AVFrame = @ptrFromInt(token);
    var retained = c.av_frame_alloc();
    if (retained == null) {
        return 0;
    }

    if (c.av_frame_ref(retained.?, source) != 0) {
        c.av_frame_free(&retained);
        return 0;
    }

    return @intFromPtr(retained.?);
}

fn queuePushLocked(
    pipeline: *c.VideoPipeline,
    src_planes: [*c][*c]u8,
    src_linesizes: [*c]c_int,
    src_plane_count: c_int,
    width: c_int,
    height: c_int,
    format: c_int,
    source_hw: c_int,
    gpu_token: u64,
    pts: f64,
) c_int {
    if (pipeline.count >= frameCapacity()) {
        return -1;
    }

    const expected_plane_count = planeCountForFormat(format);
    const gpu_only_frame = src_plane_count == 0 and source_hw != 0 and gpu_token != 0;
    if (!gpu_only_frame and src_plane_count < expected_plane_count) {
        return -1;
    }

    const tail_idx: usize = @intCast(pipeline.tail);
    const frame = &pipeline.frames[tail_idx];

    if (frame.width != width or frame.height != height) {
        return -1;
    }

    if (!gpu_only_frame) {
        var plane_idx: c_int = 0;
        while (plane_idx < expected_plane_count) : (plane_idx += 1) {
            const geometry = planeGeometry(format, width, height, plane_idx) orelse return -1;
            if (src_planes[@intCast(plane_idx)] == null or frame.planes[@intCast(plane_idx)] == null) {
                return -1;
            }

            if (src_linesizes[@intCast(plane_idx)] < @as(c_int, @intCast(geometry.row_bytes)) or frame.linesizes[@intCast(plane_idx)] < @as(c_int, @intCast(geometry.row_bytes))) {
                return -1;
            }

            const src_base: [*]const u8 = @ptrCast(src_planes[@intCast(plane_idx)]);
            const dst_base: [*]u8 = @ptrCast(frame.planes[@intCast(plane_idx)]);
            const src_stride: usize = @intCast(src_linesizes[@intCast(plane_idx)]);
            const dst_stride: usize = @intCast(frame.linesizes[@intCast(plane_idx)]);

            var row: usize = 0;
            while (row < geometry.rows) : (row += 1) {
                const dst_off = row * dst_stride;
                const src_off = row * src_stride;
                std.mem.copyForwards(u8, dst_base[dst_off .. dst_off + geometry.row_bytes], src_base[src_off .. src_off + geometry.row_bytes]);
            }
        }
    }

    const retain_token = gpu_only_frame and gpu_token != 0;
    const retained_gpu_token = if (retain_token) retainGpuToken(gpu_token) else 0;
    if (retain_token and retained_gpu_token == 0) {
        return -1;
    }

    frame.format = format;
    frame.source_hw = source_hw;
    releaseGpuToken(&frame.gpu_token);
    frame.gpu_token = retained_gpu_token;
    frame.plane_count = if (gpu_only_frame) 0 else expected_plane_count;
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

    var plane_idx: c_int = 0;
    while (plane_idx < frame.plane_count) : (plane_idx += 1) {
        const geometry = planeGeometry(frame.format, frame.width, frame.height, plane_idx) orelse return -1;
        if (frame.planes[@intCast(plane_idx)] == null or pipeline.upload_planes[@intCast(plane_idx)] == null) {
            return -1;
        }

        const frame_size = @as(usize, @intCast(frame.linesizes[@intCast(plane_idx)])) * geometry.rows;
        if (pipeline.upload_plane_sizes[@intCast(plane_idx)] < frame_size) {
            return -1;
        }

        const old_upload = pipeline.upload_planes[@intCast(plane_idx)];
        pipeline.upload_planes[@intCast(plane_idx)] = frame.planes[@intCast(plane_idx)];
        frame.planes[@intCast(plane_idx)] = old_upload;
    }

    releaseGpuToken(&pipeline.pending_gpu_token);

    pipeline.pending_width = frame.width;
    pipeline.pending_height = frame.height;
    pipeline.pending_linesizes[0] = frame.linesizes[0];
    pipeline.pending_linesizes[1] = frame.linesizes[1];
    pipeline.pending_linesizes[2] = frame.linesizes[2];
    pipeline.pending_plane_count = frame.plane_count;
    pipeline.pending_format = frame.format;
    pipeline.pending_source_hw = frame.source_hw;
    pipeline.pending_gpu_token = frame.gpu_token;
    frame.gpu_token = 0;
    pipeline.pending_pts = frame.pts;
    pipeline.have_pending_upload = 1;

    pipeline.head = @mod(pipeline.head + 1, frameCapacity());
    pipeline.count -= 1;
    if (pipeline.can_push != null) {
        _ = c.SDL_SignalCondition(pipeline.can_push);
    }
    return 0;
}

fn dropLateQueuedFramesLocked(pipeline: *c.VideoPipeline, render_clock: f64, tolerance: f64) c_int {
    if (pipeline.count <= 1) {
        return 0;
    }

    var dropped: c_int = 0;
    while (pipeline.count > 1) {
        const head_idx: usize = @intCast(pipeline.head);
        const frame = &pipeline.frames[head_idx];
        if (frame.pts + tolerance >= render_clock) {
            break;
        }

        releaseGpuToken(&frame.gpu_token);
        pipeline.head = @mod(pipeline.head + 1, frameCapacity());
        pipeline.count -= 1;
        dropped += 1;
    }

    if (dropped > 0 and pipeline.can_push != null) {
        _ = c.SDL_SignalCondition(pipeline.can_push);
    }

    return dropped;
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
        const true_zero_copy_active = pipeline.true_zero_copy_active;
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

        const format = c.player_get_video_format(pipeline.player);
        const source_hw = c.player_is_video_hw_enabled(pipeline.player);
        const gpu_token = c.player_get_video_hw_frame_token(pipeline.player);
        var planes: [3][*c]u8 = .{ null, null, null };
        var linesizes: [3]c_int = .{ 0, 0, 0 };
        var plane_count: c_int = 0;
        const gpu_only_frame = decodeShouldSkipPlaneExtraction(true_zero_copy_active, source_hw, gpu_token);

        if (!gpu_only_frame) {
            const expected_plane_count = planeCountForFormat(format);
            if (expected_plane_count > 1) {
                if (c.player_get_video_planes(pipeline.player, &planes, &linesizes, &plane_count) != 0) {
                    c.SDL_Delay(1);
                    continue;
                }
            } else {
                if (c.player_get_video_frame(pipeline.player, &planes[0], &linesizes[0]) != 0) {
                    c.SDL_Delay(1);
                    continue;
                }
                plane_count = 1;
            }
        }

        const pts = c.player_get_video_pts(pipeline.player);

        _ = c.SDL_LockMutex(pipeline.queue_mutex);
        if (pipeline.decode_running != 0) {
            if (pipeline.pts_offset_valid == 0) {
                pipeline.pts_offset = pts - pipeline.expected_start_pts;
                pipeline.pts_offset_valid = 1;
            }

            const adjusted_pts = pts - pipeline.pts_offset;
            if (queuePushLocked(pipeline, &planes, &linesizes, plane_count, pipeline.player.*.width, pipeline.player.*.height, format, source_hw, gpu_token, adjusted_pts) != 0) {
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

    const rgba_frame_size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    const y_plane_size: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    const uv_plane_size: usize = y_plane_size / 2;
    const u_plane_size: usize = y_plane_size / 4;

    var i: c_int = 0;
    while (i < frameCapacity()) : (i += 1) {
        const idx: usize = @intCast(i);
        p.frames[idx].planes[0] = @ptrCast(c.malloc(rgba_frame_size));
        p.frames[idx].planes[1] = @ptrCast(c.malloc(uv_plane_size));
        p.frames[idx].planes[2] = @ptrCast(c.malloc(u_plane_size));
        if (p.frames[idx].planes[0] == null or p.frames[idx].planes[1] == null or p.frames[idx].planes[2] == null) {
            video_pipeline_destroy(p);
            return -1;
        }

        p.frames[idx].plane_count = 1;
        p.frames[idx].format = c.VIDEO_FRAME_FORMAT_RGBA;
        p.frames[idx].width = width;
        p.frames[idx].height = height;
        p.frames[idx].linesizes[0] = width * 4;
        p.frames[idx].linesizes[1] = width;
        p.frames[idx].linesizes[2] = @divTrunc(width, 2);
        p.frames[idx].pts = 0.0;
    }

    p.upload_planes[0] = @ptrCast(c.malloc(rgba_frame_size));
    p.upload_planes[1] = @ptrCast(c.malloc(uv_plane_size));
    p.upload_planes[2] = @ptrCast(c.malloc(u_plane_size));
    if (p.upload_planes[0] == null or p.upload_planes[1] == null or p.upload_planes[2] == null) {
        video_pipeline_destroy(p);
        return -1;
    }

    p.upload_plane_sizes[0] = rgba_frame_size;
    p.upload_plane_sizes[1] = uv_plane_size;
    p.upload_plane_sizes[2] = u_plane_size;
    p.upload_plane_count = 3;
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

    var i: c_int = 0;
    while (i < frameCapacity()) : (i += 1) {
        releaseGpuToken(&p.frames[@intCast(i)].gpu_token);
    }
    releaseGpuToken(&p.pending_gpu_token);
    releaseGpuToken(&p.delivered_gpu_token);

    p.head = 0;
    p.tail = 0;
    p.count = 0;
    p.have_pending_upload = 0;
    p.pending_width = 0;
    p.pending_height = 0;
    p.pending_linesizes[0] = 0;
    p.pending_linesizes[1] = 0;
    p.pending_linesizes[2] = 0;
    p.pending_plane_count = 0;
    p.pending_format = c.VIDEO_FRAME_FORMAT_RGBA;
    p.pending_source_hw = 0;
    p.pending_gpu_token = 0;
    p.delivered_gpu_token = 0;
    p.true_zero_copy_active = 0;
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

pub export fn video_pipeline_set_true_zero_copy_active(pipeline: ?*c.VideoPipeline, active: c_int) void {
    if (pipeline == null) {
        return;
    }

    const p = pipeline.?;
    if (p.queue_mutex != null) {
        _ = c.SDL_LockMutex(p.queue_mutex);
        p.true_zero_copy_active = if (active != 0) 1 else 0;
        _ = c.SDL_UnlockMutex(p.queue_mutex);
        return;
    }

    p.true_zero_copy_active = if (active != 0) 1 else 0;
}

pub export fn video_pipeline_destroy(pipeline: ?*c.VideoPipeline) void {
    if (pipeline == null) {
        return;
    }

    const p = pipeline.?;

    video_pipeline_stop(p);

    releaseGpuToken(&p.pending_gpu_token);
    releaseGpuToken(&p.delivered_gpu_token);

    var plane_idx: c_int = 0;
    while (plane_idx < 3) : (plane_idx += 1) {
        if (p.upload_planes[@intCast(plane_idx)] != null) {
            c.free(p.upload_planes[@intCast(plane_idx)]);
            p.upload_planes[@intCast(plane_idx)] = null;
            p.upload_plane_sizes[@intCast(plane_idx)] = 0;
        }
    }

    var i: c_int = 0;
    while (i < frameCapacity()) : (i += 1) {
        const idx: usize = @intCast(i);
        plane_idx = 0;
        while (plane_idx < 3) : (plane_idx += 1) {
            if (p.frames[idx].planes[@intCast(plane_idx)] != null) {
                c.free(p.frames[idx].planes[@intCast(plane_idx)]);
                p.frames[idx].planes[@intCast(plane_idx)] = null;
            }
        }
        releaseGpuToken(&p.frames[idx].gpu_token);
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
    p.pending_source_hw = 0;
    p.pending_gpu_token = 0;
    p.delivered_gpu_token = 0;
    p.true_zero_copy_active = 0;
    p.clock_base_pts = -1.0;
    p.clock_base_time_ns = 0;
    p.expected_start_pts = 0.0;
    p.pts_offset_valid = 0;
    p.pts_offset = 0.0;
}

pub export fn video_pipeline_get_frame_for_render(
    pipeline: ?*c.VideoPipeline,
    master_clock: f64,
    planes: [*c][*c]u8,
    width: [*c]c_int,
    height: [*c]c_int,
    linesizes: [*c]c_int,
    plane_count: [*c]c_int,
    format: [*c]c_int,
    source_hw: [*c]c_int,
    gpu_token: [*c]u64,
) c_int {
    if (pipeline == null or planes == null or width == null or height == null or linesizes == null or plane_count == null or format == null or source_hw == null or gpu_token == null) {
        return -1;
    }

    const p = pipeline.?;

    releaseGpuToken(&p.delivered_gpu_token);

    if (p.have_pending_upload == 0) {
        if (p.queue_mutex != null) {
            _ = c.SDL_LockMutex(p.queue_mutex);
            if (p.count > 0) {
                if (master_clock >= 0.0) {
                    _ = dropLateQueuedFramesLocked(p, master_clock, render_late_drop_tolerance);
                }
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
        planes[0] = p.upload_planes[0];
        planes[1] = p.upload_planes[1];
        planes[2] = p.upload_planes[2];
        width.* = p.pending_width;
        height.* = p.pending_height;
        linesizes[0] = p.pending_linesizes[0];
        linesizes[1] = p.pending_linesizes[1];
        linesizes[2] = p.pending_linesizes[2];
        plane_count.* = p.pending_plane_count;
        format.* = p.pending_format;
        source_hw.* = p.pending_source_hw;
        gpu_token.* = p.pending_gpu_token;
        p.delivered_gpu_token = p.pending_gpu_token;
        p.pending_gpu_token = 0;
        p.have_pending_upload = 0;
        return 1;
    }

    return 0;
}

test "queuePushLocked records frame format metadata" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    var src: [8]u8 = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    var dst: [8]u8 = [_]u8{0} ** 8;
    var src_planes: [3][*c]u8 = .{ src[0..].ptr, null, null };
    var src_linesizes: [3]c_int = .{ 8, 0, 0 };

    pipeline.frames[0].planes[0] = dst[0..].ptr;
    pipeline.frames[0].linesizes[0] = 8;
    pipeline.frames[0].width = 2;
    pipeline.frames[0].height = 1;

    try std.testing.expectEqual(@as(c_int, 0), queuePushLocked(&pipeline, &src_planes, &src_linesizes, 1, 2, 1, c.VIDEO_FRAME_FORMAT_RGBA, 0, 0, 1.5));
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_RGBA), pipeline.frames[0].format);
    try std.testing.expectEqual(@as(c_int, 1), pipeline.frames[0].plane_count);
}

test "queuePopToUploadLocked swaps plane ownership" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    const frame_ptr: [*c]u8 = @ptrFromInt(0x1000);
    const upload_ptr: [*c]u8 = @ptrFromInt(0x2000);

    pipeline.head = 0;
    pipeline.tail = 1;
    pipeline.count = 1;
    pipeline.frames[0].planes[0] = frame_ptr;
    pipeline.frames[0].width = 320;
    pipeline.frames[0].height = 180;
    pipeline.frames[0].linesizes[0] = 1280;
    pipeline.frames[0].plane_count = 1;
    pipeline.frames[0].format = c.VIDEO_FRAME_FORMAT_RGBA;
    pipeline.frames[0].pts = 1.25;
    pipeline.upload_planes[0] = upload_ptr;
    pipeline.upload_plane_sizes[0] = 320 * 180 * 4;

    try std.testing.expectEqual(@as(c_int, 0), queuePopToUploadLocked(&pipeline));
    try std.testing.expectEqual(@as(c_int, 1), pipeline.have_pending_upload);
    try std.testing.expect(pipeline.upload_planes[0] == frame_ptr);
    try std.testing.expect(pipeline.frames[0].planes[0] == upload_ptr);
}

test "queuePopToUploadLocked preserves multi-plane pending metadata" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    const y_ptr: [*c]u8 = @ptrFromInt(0x1000);
    const uv_ptr: [*c]u8 = @ptrFromInt(0x1100);
    const upload_y_ptr: [*c]u8 = @ptrFromInt(0x2000);
    const upload_uv_ptr: [*c]u8 = @ptrFromInt(0x2100);

    pipeline.head = 0;
    pipeline.tail = 1;
    pipeline.count = 1;
    pipeline.frames[0].planes[0] = y_ptr;
    pipeline.frames[0].planes[1] = uv_ptr;
    pipeline.frames[0].width = 640;
    pipeline.frames[0].height = 360;
    pipeline.frames[0].linesizes[0] = 640;
    pipeline.frames[0].linesizes[1] = 640;
    pipeline.frames[0].plane_count = 2;
    pipeline.frames[0].format = c.VIDEO_FRAME_FORMAT_NV12;
    pipeline.frames[0].source_hw = 1;
    pipeline.frames[0].gpu_token = 0xdeadbeef;
    pipeline.frames[0].pts = 2.5;
    pipeline.upload_planes[0] = upload_y_ptr;
    pipeline.upload_planes[1] = upload_uv_ptr;
    pipeline.upload_plane_sizes[0] = 640 * 360;
    pipeline.upload_plane_sizes[1] = 640 * 180;

    try std.testing.expectEqual(@as(c_int, 0), queuePopToUploadLocked(&pipeline));
    try std.testing.expectEqual(@as(c_int, c.VIDEO_FRAME_FORMAT_NV12), pipeline.pending_format);
    try std.testing.expectEqual(@as(c_int, 1), pipeline.pending_source_hw);
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), pipeline.pending_gpu_token);
    try std.testing.expectEqual(@as(c_int, 2), pipeline.pending_plane_count);
    try std.testing.expectEqual(@as(c_int, 640), pipeline.pending_linesizes[0]);
    try std.testing.expectEqual(@as(c_int, 640), pipeline.pending_linesizes[1]);
    try std.testing.expect(pipeline.upload_planes[0] == y_ptr);
    try std.testing.expect(pipeline.upload_planes[1] == uv_ptr);
    try std.testing.expect(pipeline.frames[0].planes[0] == upload_y_ptr);
    try std.testing.expect(pipeline.frames[0].planes[1] == upload_uv_ptr);
}

test "dropLateQueuedFramesLocked keeps newest frame when queue lags" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    pipeline.count = 3;
    pipeline.head = 0;
    pipeline.tail = 3;
    pipeline.frames[0].pts = 1.0;
    pipeline.frames[1].pts = 1.03;
    pipeline.frames[2].pts = 1.20;

    const dropped = dropLateQueuedFramesLocked(&pipeline, 1.18, 0.04);
    try std.testing.expectEqual(@as(c_int, 2), dropped);
    try std.testing.expectEqual(@as(c_int, 1), pipeline.count);
    try std.testing.expectEqual(@as(c_int, 2), pipeline.head);
}

test "queuePushLocked accepts gpu-token frame with zero host planes" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    var src_planes: [3][*c]u8 = .{ null, null, null };
    var src_linesizes: [3]c_int = .{ 0, 0, 0 };
    var source_frame = try allocTestGpuFrame(1920, 1080);
    defer c.av_frame_free(&source_frame);

    pipeline.frames[0].width = 1920;
    pipeline.frames[0].height = 1080;

    try std.testing.expectEqual(
        @as(c_int, 0),
        queuePushLocked(
            &pipeline,
            &src_planes,
            &src_linesizes,
            0,
            1920,
            1080,
            c.VIDEO_FRAME_FORMAT_NV12,
            1,
            @intFromPtr(source_frame.?),
            3.0,
        ),
    );
    try std.testing.expectEqual(@as(c_int, 0), pipeline.frames[0].plane_count);
    try std.testing.expectEqual(@as(c_int, 1), pipeline.frames[0].source_hw);
    try std.testing.expect(pipeline.frames[0].gpu_token != @intFromPtr(source_frame.?));
}

test "decodeShouldSkipPlaneExtraction requires runtime true-path activation" {
    try std.testing.expect(decodeShouldSkipPlaneExtraction(1, 1, 0x1));
    try std.testing.expect(!decodeShouldSkipPlaneExtraction(1, 0, 0x1));
    try std.testing.expect(!decodeShouldSkipPlaneExtraction(1, 1, 0));
    try std.testing.expect(!decodeShouldSkipPlaneExtraction(0, 1, 0x1));
}

fn allocTestGpuFrame(width: c_int, height: c_int) !?*c.AVFrame {
    var frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    errdefer c.av_frame_free(&frame);

    frame.?.*.format = c.AV_PIX_FMT_NV12;
    frame.?.*.width = width;
    frame.?.*.height = height;
    if (c.av_frame_get_buffer(frame, 32) != 0) {
        return error.OutOfMemory;
    }

    return frame;
}

fn firstPlaneRefCount(frame: *c.AVFrame) c_int {
    if (frame.*.buf[0] == null) {
        return 0;
    }
    return c.av_buffer_get_ref_count(frame.*.buf[0]);
}

test "queuePushLocked retains independent gpu token reference" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    var src_planes: [3][*c]u8 = .{ null, null, null };
    var src_linesizes: [3]c_int = .{ 0, 0, 0 };
    var source_frame = try allocTestGpuFrame(64, 64);
    defer c.av_frame_free(&source_frame);

    pipeline.frames[0].width = 64;
    pipeline.frames[0].height = 64;

    try std.testing.expectEqual(@as(c_int, 1), firstPlaneRefCount(source_frame.?));
    try std.testing.expectEqual(
        @as(c_int, 0),
        queuePushLocked(
            &pipeline,
            &src_planes,
            &src_linesizes,
            0,
            64,
            64,
            c.VIDEO_FRAME_FORMAT_NV12,
            1,
            @intFromPtr(source_frame.?),
            0.5,
        ),
    );
    try std.testing.expect(pipeline.frames[0].gpu_token != @intFromPtr(source_frame.?));
    try std.testing.expectEqual(@as(c_int, 2), firstPlaneRefCount(source_frame.?));
}

test "dropLateQueuedFramesLocked releases dropped gpu token references" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    var src_planes: [3][*c]u8 = .{ null, null, null };
    var src_linesizes: [3]c_int = .{ 0, 0, 0 };
    var frame_a = try allocTestGpuFrame(64, 64);
    defer c.av_frame_free(&frame_a);
    var frame_b = try allocTestGpuFrame(64, 64);
    defer c.av_frame_free(&frame_b);

    pipeline.frames[0].width = 64;
    pipeline.frames[0].height = 64;
    pipeline.frames[1].width = 64;
    pipeline.frames[1].height = 64;

    try std.testing.expectEqual(@as(c_int, 0), queuePushLocked(&pipeline, &src_planes, &src_linesizes, 0, 64, 64, c.VIDEO_FRAME_FORMAT_NV12, 1, @intFromPtr(frame_a.?), 1.0));
    try std.testing.expectEqual(@as(c_int, 0), queuePushLocked(&pipeline, &src_planes, &src_linesizes, 0, 64, 64, c.VIDEO_FRAME_FORMAT_NV12, 1, @intFromPtr(frame_b.?), 1.2));
    try std.testing.expectEqual(@as(c_int, 2), firstPlaneRefCount(frame_a.?));
    try std.testing.expectEqual(@as(c_int, 2), firstPlaneRefCount(frame_b.?));

    const dropped = dropLateQueuedFramesLocked(&pipeline, 1.15, 0.01);
    try std.testing.expectEqual(@as(c_int, 1), dropped);
    try std.testing.expectEqual(@as(c_int, 1), firstPlaneRefCount(frame_a.?));
    try std.testing.expectEqual(@as(c_int, 2), firstPlaneRefCount(frame_b.?));
}

test "queuePopToUploadLocked releases prior pending gpu token before replacement" {
    var pipeline: c.VideoPipeline = std.mem.zeroes(c.VideoPipeline);
    var src_planes: [3][*c]u8 = .{ null, null, null };
    var src_linesizes: [3]c_int = .{ 0, 0, 0 };
    var frame_a = try allocTestGpuFrame(64, 64);
    defer c.av_frame_free(&frame_a);
    var frame_b = try allocTestGpuFrame(64, 64);
    defer c.av_frame_free(&frame_b);

    pipeline.frames[0].width = 64;
    pipeline.frames[0].height = 64;
    pipeline.frames[1].width = 64;
    pipeline.frames[1].height = 64;

    try std.testing.expectEqual(@as(c_int, 0), queuePushLocked(&pipeline, &src_planes, &src_linesizes, 0, 64, 64, c.VIDEO_FRAME_FORMAT_NV12, 1, @intFromPtr(frame_a.?), 1.0));
    try std.testing.expectEqual(@as(c_int, 0), queuePushLocked(&pipeline, &src_planes, &src_linesizes, 0, 64, 64, c.VIDEO_FRAME_FORMAT_NV12, 1, @intFromPtr(frame_b.?), 1.2));

    try std.testing.expectEqual(@as(c_int, 0), queuePopToUploadLocked(&pipeline));
    try std.testing.expectEqual(@as(c_int, 2), firstPlaneRefCount(frame_a.?));

    pipeline.have_pending_upload = 0;
    try std.testing.expectEqual(@as(c_int, 0), queuePopToUploadLocked(&pipeline));
    try std.testing.expectEqual(@as(c_int, 1), firstPlaneRefCount(frame_a.?));
    try std.testing.expectEqual(@as(c_int, 2), firstPlaneRefCount(frame_b.?));
}
