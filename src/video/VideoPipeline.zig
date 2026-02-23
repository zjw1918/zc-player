const std = @import("std");
const c = @import("../ffi/cplayer.zig").c;
const Player = @import("../media/Player.zig").Player;
const VideoInteropMod = @import("interop/VideoInterop.zig");
const VideoInterop = VideoInteropMod.VideoInterop;
const SoftwareUploadBackendMod = @import("interop/SoftwareUploadBackend.zig");

pub const VideoPipeline = struct {
    pub const FrameFormat = enum(c_int) {
        rgba = c.VIDEO_FRAME_FORMAT_RGBA,
        yuv420p = c.VIDEO_FRAME_FORMAT_YUV420P,
        nv12 = c.VIDEO_FRAME_FORMAT_NV12,
    };

    pub const VideoFrame = struct {
        planes: [3][*c]u8,
        linesizes: [3]c_int,
        plane_count: c_int,
        width: c_int,
        height: c_int,
        format: FrameFormat,
    };

    pub const InteropFrame = struct {
        token: u64,
        width: c_int,
        height: c_int,
        format: FrameFormat,
    };

    pub const RenderFrame = union(enum) {
        software: VideoFrame,
        interop: InteropFrame,
    };

    fn frameFormatFromTag(format: c_int) FrameFormat {
        return switch (format) {
            c.VIDEO_FRAME_FORMAT_NV12 => .nv12,
            c.VIDEO_FRAME_FORMAT_YUV420P => .yuv420p,
            else => .rgba,
        };
    }

    handle: c.VideoPipeline = undefined,
    initialized: bool = false,
    interop: ?VideoInterop = null,

    pub fn interopStatus(self: *const VideoPipeline) VideoInteropMod.RuntimeStatus {
        if (self.interop) |*interop| {
            return interop.runtimeStatus();
        }
        return .software;
    }

    pub fn interopFallbackReason(self: *const VideoPipeline) VideoInteropMod.FallbackReason {
        if (self.interop) |*interop| {
            return interop.fallbackReason();
        }
        return .none;
    }

    pub fn reportTrueZeroCopySubmitResult(self: *VideoPipeline, success: bool) void {
        if (self.interop) |*interop| {
            interop.reportTrueZeroCopySubmitResult(success);
        }
    }

    pub fn setTrueZeroCopyActive(self: *VideoPipeline, active: bool) void {
        if (!self.initialized) {
            return;
        }
        c.video_pipeline_set_true_zero_copy_active(&self.handle, if (active) 1 else 0);
    }

    pub fn init(self: *VideoPipeline, player: *Player) !void {
        if (c.video_pipeline_init(&self.handle, player.raw()) != 0) {
            return error.InitFailed;
        }
        self.initialized = true;
        const mode = VideoInterop.selectionModeFromEnvironment();
        self.interop = VideoInterop.init(mode) catch |err| {
            if (mode == .force_zero_copy) {
                std.debug.print("[interop] init failed: {s}\n", .{VideoInteropMod.initErrorReason(err)});
            }
            c.video_pipeline_destroy(&self.handle);
            self.initialized = false;
            return error.InitFailed;
        };
    }

    pub fn start(self: *VideoPipeline) !void {
        if (!self.initialized) {
            return error.NotInitialized;
        }
        if (c.video_pipeline_start(&self.handle) != 0) {
            return error.StartFailed;
        }
    }

    pub fn destroy(self: *VideoPipeline) void {
        if (!self.initialized) {
            return;
        }
        c.video_pipeline_destroy(&self.handle);
        if (self.interop) |*interop| {
            interop.deinit();
        }
        self.interop = null;
        self.initialized = false;
    }

    pub fn reset(self: *VideoPipeline) void {
        if (!self.initialized) {
            return;
        }
        c.video_pipeline_reset(&self.handle);
    }

    pub fn getFrameForRender(self: *VideoPipeline, master_clock: f64) ?RenderFrame {
        if (!self.initialized) {
            return null;
        }

        var planes: [3][*c]u8 = .{ null, null, null };
        var width: c_int = 0;
        var height: c_int = 0;
        var linesizes: [3]c_int = .{ 0, 0, 0 };
        var plane_count: c_int = 0;
        var format: c_int = c.VIDEO_FRAME_FORMAT_RGBA;
        var source_hw: c_int = 0;
        var gpu_token: u64 = 0;

        const ret = c.video_pipeline_get_frame_for_render(
            &self.handle,
            master_clock,
            &planes,
            &width,
            &height,
            &linesizes,
            &plane_count,
            &format,
            &source_hw,
            &gpu_token,
        );

        if (ret <= 0) {
            return null;
        }

        if (self.interop) |*interop| {
            const software_frame = SoftwareUploadBackendMod.SoftwarePlaneFrame{
                .planes = planes,
                .linesizes = linesizes,
                .plane_count = plane_count,
                .width = width,
                .height = height,
                .format = format,
                .pts = master_clock,
                .source_hw = source_hw != 0,
                .gpu_token = if (source_hw != 0) gpu_token else 0,
            };
            interop.submitDecodedFrame(software_frame);

            if (interop.acquireRenderableFrame()) |frame| {
                switch (frame) {
                    .software_planes => |sw| {
                        return .{ .software = .{
                            .planes = sw.planes,
                            .linesizes = sw.linesizes,
                            .plane_count = sw.plane_count,
                            .width = sw.width,
                            .height = sw.height,
                            .format = frameFormatFromTag(sw.format),
                        } };
                    },
                    .interop_handle => |handle| return .{ .interop = .{
                        .token = handle.token,
                        .width = width,
                        .height = height,
                        .format = frameFormatFromTag(format),
                    } },
                }
            }
        }

        return .{ .software = .{
            .planes = planes,
            .linesizes = linesizes,
            .plane_count = plane_count,
            .width = width,
            .height = height,
            .format = frameFormatFromTag(format),
        } };
    }
};

test "frameFormatFromTag maps known formats" {
    try std.testing.expectEqual(VideoPipeline.FrameFormat.rgba, VideoPipeline.frameFormatFromTag(c.VIDEO_FRAME_FORMAT_RGBA));
    try std.testing.expectEqual(VideoPipeline.FrameFormat.nv12, VideoPipeline.frameFormatFromTag(c.VIDEO_FRAME_FORMAT_NV12));
    try std.testing.expectEqual(VideoPipeline.FrameFormat.yuv420p, VideoPipeline.frameFormatFromTag(c.VIDEO_FRAME_FORMAT_YUV420P));
}
