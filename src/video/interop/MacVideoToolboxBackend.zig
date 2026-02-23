const builtin = @import("builtin");
const std = @import("std");

const c = @cImport({
    @cInclude("libavutil/hwcontext.h");
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

pub const MacVideoToolboxBackend = struct {
    initialized: bool = false,

    pub fn init(self: *MacVideoToolboxBackend) void {
        self.initialized = true;
    }

    pub fn deinit(self: *MacVideoToolboxBackend) void {
        self.initialized = false;
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

    pub fn submitDecodedFrame(_: *MacVideoToolboxBackend) SubmitError!void {
        return error.NotSupported;
    }

    pub fn acquireRenderableFrame(_: *MacVideoToolboxBackend) AcquireError!void {
        return error.NotSupported;
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
