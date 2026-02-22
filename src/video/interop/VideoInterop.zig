const std = @import("std");
const SoftwareUploadBackendMod = @import("SoftwareUploadBackend.zig");

pub const BackendKind = enum {
    software_upload,
    macos_videotoolbox,
};

pub const SelectionMode = enum {
    auto,
    force_software,
    force_zero_copy,
};

pub const InteropHandle = struct {
    token: u64,
};

pub const RenderableFrame = union(enum) {
    software_planes: SoftwareUploadBackendMod.SoftwarePlaneFrame,
    interop_handle: InteropHandle,
};

pub const Capabilities = struct {
    zero_copy: bool,
    supports_nv12: bool,
    supports_yuv420p: bool,
};

pub const VideoInterop = struct {
    kind: BackendKind,
    mode: SelectionMode,
    software: SoftwareUploadBackendMod.SoftwareUploadBackend,

    pub fn init(mode: SelectionMode) VideoInterop {
        var interop = VideoInterop{
            .kind = .software_upload,
            .mode = mode,
            .software = .{},
        };
        interop.software.init();
        return interop;
    }

    pub fn parseSelectionMode(value: ?[]const u8) SelectionMode {
        const text = value orelse return .auto;
        if (std.ascii.eqlIgnoreCase(text, "software")) {
            return .force_software;
        }
        if (std.ascii.eqlIgnoreCase(text, "zero_copy")) {
            return .force_zero_copy;
        }
        return .auto;
    }

    pub fn selectionModeFromEnvironment() SelectionMode {
        const value = std.posix.getenv("ZC_VIDEO_BACKEND_MODE");
        if (value == null) {
            return .auto;
        }
        return parseSelectionMode(std.mem.sliceTo(value.?, 0));
    }

    pub fn deinit(self: *VideoInterop) void {
        self.software.deinit();
    }

    pub fn capabilities(self: *const VideoInterop) Capabilities {
        const caps = self.software.capabilities();
        return .{
            .zero_copy = caps.zero_copy,
            .supports_nv12 = caps.supports_nv12,
            .supports_yuv420p = caps.supports_yuv420p,
        };
    }

    pub fn submitDecodedFrame(self: *VideoInterop, frame: SoftwareUploadBackendMod.SoftwarePlaneFrame) void {
        self.software.submitDecodedFrame(frame);
    }

    pub fn acquireRenderableFrame(self: *VideoInterop) ?RenderableFrame {
        if (self.software.acquireRenderableFrame()) |frame| {
            return .{ .software_planes = frame };
        }
        return null;
    }

    pub fn releaseFrame(self: *VideoInterop) void {
        self.software.releaseFrame();
    }
};

test "video interop defaults to software backend" {
    var interop = VideoInterop.init(.auto);
    defer interop.deinit();

    try std.testing.expectEqual(BackendKind.software_upload, interop.kind);
    const caps = interop.capabilities();
    try std.testing.expect(!caps.zero_copy);
}

test "selection parser maps known backend values" {
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode(null));
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode("auto"));
    try std.testing.expectEqual(SelectionMode.force_software, VideoInterop.parseSelectionMode("software"));
    try std.testing.expectEqual(SelectionMode.force_zero_copy, VideoInterop.parseSelectionMode("zero_copy"));
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode("unknown"));
}
