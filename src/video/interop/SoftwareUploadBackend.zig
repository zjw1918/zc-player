const std = @import("std");

pub const SoftwarePlaneFrame = struct {
    planes: [3][*c]u8,
    linesizes: [3]c_int,
    plane_count: c_int,
    width: c_int,
    height: c_int,
    format: c_int,
    pts: f64,
    source_hw: bool,
};

pub const Capabilities = struct {
    interop_handle: bool,
    true_zero_copy: bool,
    supports_nv12: bool,
    supports_yuv420p: bool,
};

pub const SoftwareUploadBackend = struct {
    latest_frame: ?SoftwarePlaneFrame = null,

    pub fn init(self: *SoftwareUploadBackend) void {
        self.* = .{};
    }

    pub fn deinit(self: *SoftwareUploadBackend) void {
        self.latest_frame = null;
    }

    pub fn capabilities(_: *const SoftwareUploadBackend) Capabilities {
        return .{
            .interop_handle = false,
            .true_zero_copy = false,
            .supports_nv12 = true,
            .supports_yuv420p = true,
        };
    }

    pub fn submitDecodedFrame(self: *SoftwareUploadBackend, frame: SoftwarePlaneFrame) void {
        self.latest_frame = frame;
    }

    pub fn acquireRenderableFrame(self: *SoftwareUploadBackend) ?SoftwarePlaneFrame {
        return self.latest_frame;
    }

    pub fn releaseFrame(self: *SoftwareUploadBackend) void {
        self.latest_frame = null;
    }
};

test "software backend capabilities report no zero-copy" {
    var backend = SoftwareUploadBackend{};
    backend.init();
    defer backend.deinit();

    const caps = backend.capabilities();
    try std.testing.expect(!caps.interop_handle);
    try std.testing.expect(!caps.true_zero_copy);
    try std.testing.expect(caps.supports_nv12);
    try std.testing.expect(caps.supports_yuv420p);
}
