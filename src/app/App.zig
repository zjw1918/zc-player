const std = @import("std");
const PlaybackEngine = @import("../engine/PlaybackEngine.zig").PlaybackEngine;
const SnapshotMod = @import("../engine/Snapshot.zig");
const PlaybackState = SnapshotMod.PlaybackState;
const gui = @import("../ffi/gui.zig").c;

const UploadPath = enum {
    rgba,
    nv12,
    yuv420p,
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
                            _ = gui.renderer_submit_interop_handle(
                                &renderer,
                                interop.token,
                                interop.width,
                                interop.height,
                                @intFromEnum(interop.format),
                            );
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
