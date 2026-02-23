const builtin = @import("builtin");
const std = @import("std");
const SoftwareUploadBackendMod = @import("SoftwareUploadBackend.zig");

const c = @cImport({
    @cInclude("libavutil/hwcontext.h");
    @cInclude("renderer/renderer.h");
});

pub const Capabilities = struct {
    zero_copy: bool,
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

    pub fn init(self: *MacVideoToolboxBackend) void {
        self.initialized = true;
        self.host_frame = std.mem.zeroes(c.RendererInteropHostFrame);
        self.has_frame = false;
    }

    pub fn deinit(self: *MacVideoToolboxBackend) void {
        self.initialized = false;
        self.host_frame = std.mem.zeroes(c.RendererInteropHostFrame);
        self.has_frame = false;
    }

    pub fn capabilities(_: *const MacVideoToolboxBackend) Capabilities {
        if (builtin.os.tag != .macos) {
            return .{ .zero_copy = false, .supports_nv12 = false, .supports_yuv420p = false };
        }

        const has_vt = c.av_hwdevice_find_type_by_name("videotoolbox") != c.AV_HWDEVICE_TYPE_NONE;
        return .{
            .zero_copy = has_vt,
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
        self.has_frame = true;
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
    try std.testing.expect(!caps.zero_copy);
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
    };

    try backend.submitDecodedFrame(frame);
    const handle = try backend.acquireRenderableFrame();
    try std.testing.expect(handle != null);
}
