const builtin = @import("builtin");
const std = @import("std");
const SoftwareUploadBackendMod = @import("SoftwareUploadBackend.zig");

const c = @cImport({
    @cInclude("libavutil/hwcontext.h");
    @cInclude("renderer/renderer.h");
});

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

    pub fn init(self: *MacVideoToolboxBackend) void {
        self.initialized = true;
        self.host_frame = std.mem.zeroes(c.RendererInteropHostFrame);
        self.has_frame = false;
        self.hw_frame_streak = 0;
        self.true_zero_copy_capable = self.capabilities().true_zero_copy;
    }

    pub fn deinit(self: *MacVideoToolboxBackend) void {
        self.initialized = false;
        self.host_frame = std.mem.zeroes(c.RendererInteropHostFrame);
        self.has_frame = false;
        self.hw_frame_streak = 0;
        self.true_zero_copy_capable = false;
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
        if (frame.source_hw) {
            self.hw_frame_streak += 1;
        } else {
            self.hw_frame_streak = 0;
        }
        self.has_frame = true;
    }

    pub fn trueZeroCopyActive(self: *const MacVideoToolboxBackend) bool {
        return trueZeroCopyActiveForStreak(self.true_zero_copy_capable, self.hw_frame_streak, true_zero_copy_hw_streak_threshold);
    }

    pub fn acquireRenderableFrame(self: *MacVideoToolboxBackend) AcquireError!?InteropHandle {
        if (!self.initialized) {
            return error.NotSupported;
        }
        if (!self.has_frame) {
            return null;
        }

        return InteropHandle{
            .token = @intFromPtr(&self.host_frame),
        };
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
