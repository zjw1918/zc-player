const std = @import("std");
const PlaybackEngine = @import("../engine/PlaybackEngine.zig").PlaybackEngine;
const SnapshotMod = @import("../engine/Snapshot.zig");
const PlaybackState = SnapshotMod.PlaybackState;
const VideoBackendStatus = SnapshotMod.VideoBackendStatus;
const VideoFallbackReason = SnapshotMod.VideoFallbackReason;
const gui = @import("../ffi/gui.zig").c;
const libc = @cImport({
    @cInclude("stdlib.h");
});

const force_interop_env_name = "ZC_FORCE_INTEROP_HANDLE";

const UploadPath = enum {
    rgba,
    nv12,
    yuv420p,
};

const InteropSubmitPath = enum {
    interop_handle,
    true_zero_copy,
};

fn selectUploadPath(format: c_int, plane_count: c_int) UploadPath {
    if (format == gui.VIDEO_FRAME_FORMAT_NV12 and plane_count >= 2) {
        return .nv12;
    }
    if (format == gui.VIDEO_FRAME_FORMAT_YUV420P and plane_count >= 3) {
        return .yuv420p;
    }
    return .rgba;
}

fn playerStateFromValue(value: c_int) gui.PlayerState {
    return switch (@typeInfo(gui.PlayerState)) {
        .@"enum" => @enumFromInt(value),
        else => @as(gui.PlayerState, @intCast(value)),
    };
}

fn toGuiPlayerState(state: PlaybackState) gui.PlayerState {
    const value: c_int = switch (state) {
        .stopped => gui.PLAYER_STATE_STOPPED,
        .playing => gui.PLAYER_STATE_PLAYING,
        .paused => gui.PLAYER_STATE_PAUSED,
        .buffering => gui.PLAYER_STATE_BUFFERING,
    };

    return playerStateFromValue(value);
}

fn toGuiBackendStatus(status: VideoBackendStatus) c_int {
    return switch (status) {
        .software => gui.VIDEO_BACKEND_STATUS_SOFTWARE,
        .interop_handle => gui.VIDEO_BACKEND_STATUS_INTEROP_HANDLE,
        .true_zero_copy => gui.VIDEO_BACKEND_STATUS_TRUE_ZERO_COPY,
        .force_zero_copy_blocked => gui.VIDEO_BACKEND_STATUS_FORCE_ZERO_COPY_BLOCKED,
    };
}

fn toGuiFallbackReason(reason: VideoFallbackReason) c_int {
    return switch (reason) {
        .none => gui.VIDEO_FALLBACK_REASON_NONE,
        .unsupported_mode => gui.VIDEO_FALLBACK_REASON_UNSUPPORTED_MODE,
        .backend_failure => gui.VIDEO_FALLBACK_REASON_BACKEND_FAILURE,
        .import_failure => gui.VIDEO_FALLBACK_REASON_IMPORT_FAILURE,
        .format_not_supported => gui.VIDEO_FALLBACK_REASON_FORMAT_NOT_SUPPORTED,
    };
}

fn selectInteropSubmitPath(status: VideoBackendStatus) InteropSubmitPath {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, force_interop_env_name)) |value| {
        defer std.heap.page_allocator.free(value);
        if (std.mem.eql(u8, value, "1")) {
            return .interop_handle;
        }
    } else |_| {}

    return if (status == .true_zero_copy) .true_zero_copy else .interop_handle;
}

fn captureForceInteropEnv() !?[]u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, force_interop_env_name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn restoreForceInteropEnv(previous: ?[]const u8) !void {
    if (previous) |value| {
        const value_z = try std.heap.page_allocator.dupeZ(u8, value);
        defer std.heap.page_allocator.free(value_z);
        try std.testing.expectEqual(@as(c_int, 0), libc.setenv(force_interop_env_name, value_z, 1));
        return;
    }

    try std.testing.expectEqual(@as(c_int, 0), libc.unsetenv(force_interop_env_name));
}

fn isGpuInteropPayload(handle_token: u64) bool {
    if (handle_token == 0) {
        return false;
    }

    const frame: *const gui.RendererInteropHostFrame = @ptrFromInt(handle_token);
    return frame.payload_kind == gui.RENDERER_INTEROP_PAYLOAD_GPU and frame.gpu_token != 0;
}

fn renderVideoCallback(userdata: ?*anyopaque) callconv(.c) void {
    if (userdata == null) {
        return;
    }

    const renderer: *gui.Renderer = @ptrCast(@alignCast(userdata.?));
    gui.renderer_render(renderer);

    if (renderer.app == null) {
        return;
    }

    const app = renderer.app;
    if (app.*.command_buffers == null or app.*.swapchain_image_count == 0) {
        return;
    }

    gui.ui_draw(app.*.command_buffers[app.*.current_frame]);
}

fn swapchainRecreatedCallback(userdata: ?*anyopaque) callconv(.c) void {
    if (userdata == null) {
        return;
    }

    const renderer: *gui.Renderer = @ptrCast(@alignCast(userdata.?));
    if (gui.renderer_recreate_for_swapchain(renderer) != 0) {
        if (renderer.app != null) {
            renderer.app.*.running = 0;
        }
        return;
    }

    if (renderer.app == null) {
        return;
    }

    gui.ui_on_swapchain_recreated(renderer.app);
}

pub const App = struct {
    allocator: std.mem.Allocator,
    engine: PlaybackEngine,

    pub fn init(allocator: std.mem.Allocator) App {
        return App{
            .allocator = allocator,
            .engine = PlaybackEngine.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.engine.deinit();
    }

    pub fn run(self: *App, media_path: ?[]const u8) !void {
        _ = self.allocator;

        var app: gui.App = std.mem.zeroes(gui.App);
        if (gui.app_init(&app, "ZCPlayer - Vulkan Video Player", 1280, 720) != 0) {
            return error.AppInitFailed;
        }
        defer gui.app_destroy(&app);

        var renderer: gui.Renderer = std.mem.zeroes(gui.Renderer);
        if (gui.renderer_init(&renderer, &app) != 0) {
            return error.RendererInitFailed;
        }
        defer gui.renderer_destroy(&renderer);

        gui.app_set_render_callback(&app, renderVideoCallback, &renderer);
        gui.app_set_swapchain_recreate_callback(&app, swapchainRecreatedCallback, &renderer);

        if (gui.ui_init(&app) != 0) {
            return error.UiInitFailed;
        }
        defer gui.ui_shutdown();

        try self.engine.start();
        defer self.engine.stop();

        if (media_path) |path| {
            _ = self.engine.sendOpen(path) catch {};
        }

        var ui_state: gui.UIState = .{
            .seek_changed = 0,
            .seek_value = 0.0,
        };

        while (app.running != 0) {
            _ = gui.app_poll_events(&app);
            if (app.running == 0) {
                break;
            }

            var selected_path: [1024]u8 = [_]u8{0} ** 1024;
            if (gui.ui_take_selected_file(&selected_path[0], selected_path.len) != 0) {
                const c_path: [*:0]const u8 = @ptrCast(&selected_path[0]);
                const path = std.mem.span(c_path);
                _ = self.engine.sendOpen(path) catch {};
            }

            var action: gui.UIAction = undefined;
            while (gui.ui_take_action(&action) != 0) {
                switch (action.type) {
                    gui.UI_ACTION_PLAY => {
                        _ = self.engine.sendPlay() catch {};
                    },
                    gui.UI_ACTION_PAUSE => {
                        _ = self.engine.sendPause() catch {};
                    },
                    gui.UI_ACTION_STOP => {
                        _ = self.engine.sendStop() catch {};
                    },
                    gui.UI_ACTION_TOGGLE_PLAY_PAUSE => {
                        const snapshot = self.engine.getSnapshot();
                        if (snapshot.state == .playing) {
                            _ = self.engine.sendPause() catch {};
                        } else {
                            _ = self.engine.sendPlay() catch {};
                        }
                    },
                    gui.UI_ACTION_SEEK_ABS => {
                        _ = self.engine.sendSeekAbs(action.value) catch {};
                    },
                    gui.UI_ACTION_SET_VOLUME => {
                        _ = self.engine.sendVolume(action.value) catch {};
                    },
                    gui.UI_ACTION_SET_SPEED => {
                        _ = self.engine.sendSpeed(action.value) catch {};
                    },
                    gui.UI_ACTION_NONE => {},
                    else => {},
                }
            }

            const snapshot = self.engine.getSnapshot();

            if (snapshot.state == .playing) {
                if (self.engine.getFrameForRender(snapshot.current_time)) |frame| {
                    switch (frame) {
                        .software => |sw| {
                            const path = selectUploadPath(@intFromEnum(sw.format), sw.plane_count);
                            switch (path) {
                                .nv12 => {
                                    _ = gui.renderer_upload_video_nv12(
                                        &renderer,
                                        sw.planes[0],
                                        sw.linesizes[0],
                                        sw.planes[1],
                                        sw.linesizes[1],
                                        sw.width,
                                        sw.height,
                                    );
                                },
                                .yuv420p => {
                                    _ = gui.renderer_upload_video_yuv420p(
                                        &renderer,
                                        sw.planes[0],
                                        sw.linesizes[0],
                                        sw.planes[1],
                                        sw.linesizes[1],
                                        sw.planes[2],
                                        sw.linesizes[2],
                                        sw.width,
                                        sw.height,
                                    );
                                },
                                .rgba => {
                                    _ = gui.renderer_upload_video(
                                        &renderer,
                                        sw.planes[0],
                                        sw.width,
                                        sw.height,
                                        sw.linesizes[0],
                                    );
                                },
                            }
                        },
                        .interop => |interop| {
                            const gpu_payload = isGpuInteropPayload(interop.token);
                            var submit_result: c_int = -1;
                            const path = selectInteropSubmitPath(snapshot.video_backend_status);
                            switch (path) {
                                .true_zero_copy => {
                                    submit_result = gui.renderer_submit_true_zero_copy_handle(
                                        &renderer,
                                        interop.token,
                                        interop.width,
                                        interop.height,
                                        @intFromEnum(interop.format),
                                    );
                                },
                                .interop_handle => {
                                    submit_result = gui.renderer_submit_interop_handle(
                                        &renderer,
                                        interop.token,
                                        interop.width,
                                        interop.height,
                                        @intFromEnum(interop.format),
                                    );
                                },
                            }

                            if (gpu_payload and path == .true_zero_copy) {
                                self.engine.reportTrueZeroCopySubmitResult(submit_result == 0);
                            }
                        },
                    }
                }
            }

            var ui_snapshot: gui.PlaybackSnapshot = .{
                .state = toGuiPlayerState(snapshot.state),
                .current_time = snapshot.current_time,
                .duration = snapshot.duration,
                .volume = snapshot.volume,
                .playback_speed = snapshot.playback_speed,
                .has_media = if (snapshot.has_media) 1 else 0,
                .video_backend_status = toGuiBackendStatus(snapshot.video_backend_status),
                .video_fallback_reason = toGuiFallbackReason(snapshot.video_fallback_reason),
            };

            gui.ui_new_frame();
            gui.ui_render(&ui_state, &ui_snapshot);
            gui.app_present(&app);
            gui.SDL_Delay(16);
        }
    }
};

test "swapchain recreate callback stops app on renderer recreate failure" {
    var app: gui.App = std.mem.zeroes(gui.App);
    app.running = 1;

    var renderer: gui.Renderer = std.mem.zeroes(gui.Renderer);
    renderer.app = &app;

    swapchainRecreatedCallback(&renderer);
    try std.testing.expect(app.running == 0);
}

test "swapchain recreate callback handles null userdata" {
    swapchainRecreatedCallback(null);
}

test "selectUploadPath prefers nv12 and yuv420p over rgba" {
    try std.testing.expectEqual(.nv12, selectUploadPath(gui.VIDEO_FRAME_FORMAT_NV12, 2));
    try std.testing.expectEqual(.yuv420p, selectUploadPath(gui.VIDEO_FRAME_FORMAT_YUV420P, 3));
    try std.testing.expectEqual(.rgba, selectUploadPath(gui.VIDEO_FRAME_FORMAT_RGBA, 1));
}

test "selectUploadPath falls back to rgba when planes are incomplete" {
    try std.testing.expectEqual(.rgba, selectUploadPath(gui.VIDEO_FRAME_FORMAT_NV12, 1));
    try std.testing.expectEqual(.rgba, selectUploadPath(gui.VIDEO_FRAME_FORMAT_YUV420P, 2));
}

test "toGuiBackendStatus maps interop statuses" {
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_BACKEND_STATUS_SOFTWARE), toGuiBackendStatus(.software));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_BACKEND_STATUS_INTEROP_HANDLE), toGuiBackendStatus(.interop_handle));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_BACKEND_STATUS_TRUE_ZERO_COPY), toGuiBackendStatus(.true_zero_copy));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_BACKEND_STATUS_FORCE_ZERO_COPY_BLOCKED), toGuiBackendStatus(.force_zero_copy_blocked));
}

test "toGuiFallbackReason maps interop fallback reasons" {
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_FALLBACK_REASON_NONE), toGuiFallbackReason(.none));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_FALLBACK_REASON_UNSUPPORTED_MODE), toGuiFallbackReason(.unsupported_mode));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_FALLBACK_REASON_BACKEND_FAILURE), toGuiFallbackReason(.backend_failure));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_FALLBACK_REASON_IMPORT_FAILURE), toGuiFallbackReason(.import_failure));
    try std.testing.expectEqual(@as(c_int, gui.VIDEO_FALLBACK_REASON_FORMAT_NOT_SUPPORTED), toGuiFallbackReason(.format_not_supported));
}

test "selectInteropSubmitPath chooses true-zero-copy when active" {
    try std.testing.expectEqual(InteropSubmitPath.true_zero_copy, selectInteropSubmitPath(.true_zero_copy));
    try std.testing.expectEqual(InteropSubmitPath.interop_handle, selectInteropSubmitPath(.interop_handle));
    try std.testing.expectEqual(InteropSubmitPath.interop_handle, selectInteropSubmitPath(.software));
}

test "selectInteropSubmitPath forces interop when env override set" {
    const previous = try captureForceInteropEnv();
    defer if (previous) |value| std.heap.page_allocator.free(value);
    defer restoreForceInteropEnv(previous) catch unreachable;

    try std.testing.expectEqual(@as(c_int, 0), libc.setenv(force_interop_env_name, "1", 1));

    try std.testing.expectEqual(InteropSubmitPath.interop_handle, selectInteropSubmitPath(.true_zero_copy));
}

test "isGpuInteropPayload detects gpu-tagged interop frames" {
    var frame: gui.RendererInteropHostFrame = std.mem.zeroes(gui.RendererInteropHostFrame);
    frame.payload_kind = gui.RENDERER_INTEROP_PAYLOAD_GPU;
    frame.gpu_token = 1;
    try std.testing.expect(isGpuInteropPayload(@intFromPtr(&frame)));

    frame.payload_kind = gui.RENDERER_INTEROP_PAYLOAD_HOST;
    try std.testing.expect(!isGpuInteropPayload(@intFromPtr(&frame)));
}
