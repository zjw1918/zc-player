const builtin = @import("builtin");
const std = @import("std");
const SoftwareUploadBackendMod = @import("SoftwareUploadBackend.zig");

const c = @cImport({
    @cInclude("libavutil/frame.h");
    @cInclude("libavutil/hwcontext.h");
    @cInclude("renderer/renderer.h");
});

const frame_format_rgba: c_int = 0;
const frame_format_nv12: c_int = 2;

fn probeTrueZeroCopySupportForValue(flag_value: ?[]const u8, has_vt: bool, is_macos: bool) bool {
    if (!is_macos or !has_vt) {
        return false;
    }

    const value = flag_value orelse return false;
    return value.len > 0 and value[0] != '0';
}

fn trueZeroCopyActiveForStreak(capable: bool, hw_frame_streak: u32, threshold: u32) bool {
    return capable and hw_frame_streak >= threshold;
}

const true_zero_copy_hw_streak_threshold: u32 = 12;
const true_zero_copy_required_format: c_int = frame_format_nv12;

pub const Capabilities = struct {
    interop_handle: bool,
    true_zero_copy: bool,
    supports_nv12: bool,
    supports_yuv420p: bool,
};

pub const SubmitError = error{
    NotSupported,
};

pub const AcquireError = error{
    NotSupported,
};

pub const InteropHandle = struct {
    token: u64,
};

pub const MacVideoToolboxBackend = struct {
    initialized: bool = false,
    host_frame: c.RendererInteropHostFrame = std.mem.zeroes(c.RendererInteropHostFrame),
    has_frame: bool = false,
    hw_frame_streak: u32 = 0,
    true_zero_copy_capable: bool = false,
    retained_gpu_frame: ?*c.AVFrame = null,
    frame_generation: u32 = 0,
    frame_in_flight: bool = false,
    last_frame_format: c_int = frame_format_rgba,

    pub fn init(self: *MacVideoToolboxBackend) void {
        self.initialized = true;
        self.host_frame = std.mem.zeroes(c.RendererInteropHostFrame);
        self.has_frame = false;
        self.hw_frame_streak = 0;
        self.true_zero_copy_capable = self.capabilities().true_zero_copy;
        self.retained_gpu_frame = null;
        self.frame_generation = 0;
        self.frame_in_flight = false;
        self.last_frame_format = frame_format_rgba;
    }

    pub fn deinit(self: *MacVideoToolboxBackend) void {
        self.initialized = false;
        self.host_frame = std.mem.zeroes(c.RendererInteropHostFrame);
        self.has_frame = false;
        self.hw_frame_streak = 0;
        self.true_zero_copy_capable = false;
        if (self.retained_gpu_frame != null) {
            c.av_frame_free(&self.retained_gpu_frame);
        }
        self.frame_generation = 0;
        self.frame_in_flight = false;
        self.last_frame_format = frame_format_rgba;
    }

    pub fn capabilities(_: *const MacVideoToolboxBackend) Capabilities {
        const is_macos = builtin.os.tag == .macos;
        if (!is_macos) {
            return .{ .interop_handle = false, .true_zero_copy = false, .supports_nv12 = false, .supports_yuv420p = false };
        }

        const has_vt = c.av_hwdevice_find_type_by_name("videotoolbox") != c.AV_HWDEVICE_TYPE_NONE;
        const probe_flag = std.posix.getenv("ZC_EXPERIMENTAL_TRUE_ZERO_COPY");
        const probe_enabled = probeTrueZeroCopySupportForValue(
            if (probe_flag) |value| std.mem.sliceTo(value, 0) else null,
            has_vt,
            is_macos,
        );
        return .{
            .interop_handle = has_vt,
            .true_zero_copy = probe_enabled,
            .supports_nv12 = has_vt,
            .supports_yuv420p = has_vt,
        };
    }

    pub fn submitDecodedFrame(self: *MacVideoToolboxBackend, frame: SoftwareUploadBackendMod.SoftwarePlaneFrame) SubmitError!void {
        if (!self.initialized) {
            return error.NotSupported;
        }

        self.host_frame.planes[0] = frame.planes[0];
        self.host_frame.planes[1] = frame.planes[1];
        self.host_frame.planes[2] = frame.planes[2];
        self.host_frame.linesizes[0] = frame.linesizes[0];
        self.host_frame.linesizes[1] = frame.linesizes[1];
        self.host_frame.linesizes[2] = frame.linesizes[2];
        self.host_frame.plane_count = frame.plane_count;
        self.host_frame.width = frame.width;
        self.host_frame.height = frame.height;
        self.host_frame.format = frame.format;
        self.host_frame.source_is_hw = if (frame.source_hw) 1 else 0;
        self.last_frame_format = frame.format;
        self.host_frame.payload_kind = c.RENDERER_INTEROP_PAYLOAD_HOST;
        self.host_frame.gpu_token = 0;
        if (self.retained_gpu_frame != null) {
            c.av_frame_free(&self.retained_gpu_frame);
        }
        if (frame.source_hw and frame.format == frame_format_nv12 and frame.gpu_token != 0) {
            const source_frame: *c.AVFrame = @ptrFromInt(frame.gpu_token);

            self.retained_gpu_frame = c.av_frame_alloc();
            if (self.retained_gpu_frame != null) {
                if (c.av_frame_ref(self.retained_gpu_frame, source_frame) == 0) {
                    self.host_frame.payload_kind = c.RENDERER_INTEROP_PAYLOAD_GPU;
                    self.host_frame.gpu_token = @intFromPtr(self.retained_gpu_frame);
                }
            }
        }
        self.frame_generation +%= 1;
        self.frame_in_flight = false;
        if (frame.source_hw) {
            self.hw_frame_streak += 1;
        } else {
            self.hw_frame_streak = 0;
        }
        self.has_frame = true;
    }

    pub fn trueZeroCopyActive(self: *const MacVideoToolboxBackend) bool {
        if (self.last_frame_format != true_zero_copy_required_format) {
            return false;
        }

        return trueZeroCopyActiveForStreak(self.true_zero_copy_capable, self.hw_frame_streak, true_zero_copy_hw_streak_threshold);
    }

    pub fn trueZeroCopyPayloadReady(self: *const MacVideoToolboxBackend) bool {
        return self.host_frame.payload_kind == c.RENDERER_INTEROP_PAYLOAD_GPU and self.host_frame.gpu_token != 0;
    }

    pub fn acquireRenderableFrame(self: *MacVideoToolboxBackend) AcquireError!?InteropHandle {
        if (!self.initialized) {
            return error.NotSupported;
        }
        if (!self.has_frame) {
            return null;
        }
        if (self.frame_in_flight) {
            return null;
        }

        self.frame_in_flight = true;

        return InteropHandle{
            .token = @intFromPtr(&self.host_frame),
        };
    }

    pub fn resolveHandle(self: *MacVideoToolboxBackend, handle: InteropHandle) ?*c.RendererInteropHostFrame {
        if (!self.frame_in_flight) {
            return null;
        }

        if (handle.token != @intFromPtr(&self.host_frame)) {
            return null;
        }

        return &self.host_frame;
    }

    pub fn releaseRenderableFrame(self: *MacVideoToolboxBackend, handle: InteropHandle) void {
        if (handle.token != @intFromPtr(&self.host_frame)) {
            return;
        }

        self.frame_in_flight = false;
    }
};

test "mac videotoolbox backend reports unavailable off macos" {
    if (builtin.os.tag == .macos) {
        return;
    }

    var backend = MacVideoToolboxBackend{};
    const caps = backend.capabilities();
    try std.testing.expect(!caps.interop_handle);
    try std.testing.expect(!caps.true_zero_copy);
}

test "mac backend returns interop handle after submit" {
    var backend = MacVideoToolboxBackend{};
    backend.init();
    defer backend.deinit();

    const frame = SoftwareUploadBackendMod.SoftwarePlaneFrame{
        .planes = .{ null, null, null },
        .linesizes = .{ 0, 0, 0 },
        .plane_count = 1,
        .width = 16,
        .height = 16,
        .format = 0,
        .pts = 0.0,
        .source_hw = false,
        .gpu_token = 0,
    };

    try backend.submitDecodedFrame(frame);
    const handle = try backend.acquireRenderableFrame();
    try std.testing.expect(handle != null);
}

test "true zero-copy probe requires explicit opt-in flag" {
    try std.testing.expect(!probeTrueZeroCopySupportForValue(null, true, true));
    try std.testing.expect(!probeTrueZeroCopySupportForValue("0", true, true));
    try std.testing.expect(probeTrueZeroCopySupportForValue("1", true, true));
}

test "true zero-copy probe still requires platform capability" {
    try std.testing.expect(!probeTrueZeroCopySupportForValue("1", false, true));
    try std.testing.expect(!probeTrueZeroCopySupportForValue("1", true, false));
}

test "true zero-copy active requires sustained hardware frames" {
    try std.testing.expect(!trueZeroCopyActiveForStreak(true, 5, 12));
    try std.testing.expect(trueZeroCopyActiveForStreak(true, 12, 12));
    try std.testing.expect(!trueZeroCopyActiveForStreak(false, 20, 12));
}

test "true zero-copy active requires nv12 format" {
    var backend = MacVideoToolboxBackend{};
    backend.init();
    defer backend.deinit();

    backend.true_zero_copy_capable = true;
    backend.hw_frame_streak = true_zero_copy_hw_streak_threshold;
    backend.last_frame_format = frame_format_rgba;

    try std.testing.expect(!backend.trueZeroCopyActive());
}

test "interop contract marks host bridge payload kind" {
    var backend = MacVideoToolboxBackend{};
    backend.init();
    defer backend.deinit();

    const frame = SoftwareUploadBackendMod.SoftwarePlaneFrame{
        .planes = .{ null, null, null },
        .linesizes = .{ 0, 0, 0 },
        .plane_count = 1,
        .width = 16,
        .height = 16,
        .format = 0,
        .pts = 0.0,
        .source_hw = false,
        .gpu_token = 0,
    };

    try backend.submitDecodedFrame(frame);
    try std.testing.expectEqual(@as(c_int, c.RENDERER_INTEROP_PAYLOAD_HOST), backend.host_frame.payload_kind);
}

test "in-flight frame slot lifecycle requires release before reacquire" {
    var backend = MacVideoToolboxBackend{};
    backend.init();
    defer backend.deinit();

    const frame = SoftwareUploadBackendMod.SoftwarePlaneFrame{
        .planes = .{ null, null, null },
        .linesizes = .{ 0, 0, 0 },
        .plane_count = 1,
        .width = 16,
        .height = 16,
        .format = 0,
        .pts = 0.0,
        .source_hw = false,
        .gpu_token = 0,
    };

    try backend.submitDecodedFrame(frame);
    const handle = (try backend.acquireRenderableFrame()).?;
    try std.testing.expect((try backend.acquireRenderableFrame()) == null);

    backend.releaseRenderableFrame(handle);
    try std.testing.expect((try backend.acquireRenderableFrame()) != null);
}

test "nv12 hardware frame with gpu token marks gpu payload" {
    var backend = MacVideoToolboxBackend{};
    backend.init();
    defer backend.deinit();

    var source_frame = c.av_frame_alloc();
    defer c.av_frame_free(&source_frame);

    if (source_frame == null) {
        return error.OutOfMemory;
    }

    source_frame.?.*.format = c.AV_PIX_FMT_NV12;
    source_frame.?.*.width = 64;
    source_frame.?.*.height = 64;
    if (c.av_frame_get_buffer(source_frame, 32) != 0) {
        return error.OutOfMemory;
    }

    const frame = SoftwareUploadBackendMod.SoftwarePlaneFrame{
        .planes = .{ null, null, null },
        .linesizes = .{ 0, 0, 0 },
        .plane_count = 2,
        .width = 64,
        .height = 64,
        .format = frame_format_nv12,
        .pts = 0.0,
        .source_hw = true,
        .gpu_token = @intFromPtr(source_frame),
    };

    try backend.submitDecodedFrame(frame);
    try std.testing.expectEqual(@as(c_int, c.RENDERER_INTEROP_PAYLOAD_GPU), backend.host_frame.payload_kind);
    try std.testing.expect(backend.host_frame.gpu_token != 0);
}
