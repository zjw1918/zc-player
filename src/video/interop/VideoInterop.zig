const std = @import("std");
const SoftwareUploadBackendMod = @import("SoftwareUploadBackend.zig");
const MacVideoToolboxBackendMod = @import("MacVideoToolboxBackend.zig");

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
    mac_backend: MacVideoToolboxBackendMod.MacVideoToolboxBackend,
    fallback_switches: u32,
    consecutive_failures: u32,
    failure_threshold: u32,
    submit_success_count: u64,
    submit_failure_count: u64,
    acquire_failure_count: u64,

    pub fn init(mode: SelectionMode) VideoInterop {
        var interop = VideoInterop{
            .kind = .software_upload,
            .mode = mode,
            .software = .{},
            .mac_backend = .{},
            .fallback_switches = 0,
            .consecutive_failures = 0,
            .failure_threshold = 3,
            .submit_success_count = 0,
            .submit_failure_count = 0,
            .acquire_failure_count = 0,
        };
        interop.software.init();
        interop.mac_backend.init();
        interop.kind = interop.resolveBackendKind();
        return interop;
    }

    fn resolveBackendKind(self: *const VideoInterop) BackendKind {
        const mac_caps = self.mac_backend.capabilities();
        return switch (self.mode) {
            .force_software => .software_upload,
            .force_zero_copy => if (mac_caps.zero_copy) .macos_videotoolbox else .software_upload,
            .auto => if (mac_caps.zero_copy) .macos_videotoolbox else .software_upload,
        };
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
        self.mac_backend.deinit();
        self.software.deinit();
    }

    fn recordFailure(self: *VideoInterop) void {
        self.submit_failure_count += 1;
        self.consecutive_failures += 1;
        if (self.kind == .macos_videotoolbox and self.consecutive_failures >= self.failure_threshold) {
            self.kind = .software_upload;
            self.fallback_switches += 1;
        }
    }

    fn recordSuccess(self: *VideoInterop) void {
        self.consecutive_failures = 0;
        self.submit_success_count += 1;
    }

    pub fn diagnosticsEnabled() bool {
        const value = std.posix.getenv("ZC_DEBUG_INTEROP");
        if (value == null) {
            return false;
        }
        return value.?[0] != 0 and value.?[0] != '0';
    }

    pub fn capabilities(self: *const VideoInterop) Capabilities {
        const caps = switch (self.kind) {
            .software_upload => self.software.capabilities(),
            .macos_videotoolbox => blk: {
                const mac_caps = self.mac_backend.capabilities();
                break :blk SoftwareUploadBackendMod.Capabilities{
                    .zero_copy = mac_caps.zero_copy,
                    .supports_nv12 = mac_caps.supports_nv12,
                    .supports_yuv420p = mac_caps.supports_yuv420p,
                };
            },
        };
        return .{
            .zero_copy = caps.zero_copy,
            .supports_nv12 = caps.supports_nv12,
            .supports_yuv420p = caps.supports_yuv420p,
        };
    }

    pub fn submitDecodedFrame(self: *VideoInterop, frame: SoftwareUploadBackendMod.SoftwarePlaneFrame) void {
        self.software.submitDecodedFrame(frame);

        if (self.kind == .macos_videotoolbox) {
            self.mac_backend.submitDecodedFrame(frame) catch {
                self.recordFailure();
                return;
            };
            self.recordSuccess();
        }
    }

    pub fn acquireRenderableFrame(self: *VideoInterop) ?RenderableFrame {
        if (self.kind == .macos_videotoolbox) {
            const maybe_handle = self.mac_backend.acquireRenderableFrame() catch {
                self.acquire_failure_count += 1;
                self.recordFailure();
                return null;
            };

            if (maybe_handle) |handle| {
                self.recordSuccess();
                return .{ .interop_handle = .{ .token = handle.token } };
            }
        }

        if (self.software.acquireRenderableFrame()) |frame| {
            return .{ .software_planes = frame };
        }
        return null;
    }

    pub fn releaseFrame(self: *VideoInterop) void {
        self.software.releaseFrame();
    }
};

test "video interop auto mode selects available backend" {
    var interop = VideoInterop.init(.auto);
    defer interop.deinit();

    const mac_caps = interop.mac_backend.capabilities();
    const expected: BackendKind = if (mac_caps.zero_copy) .macos_videotoolbox else .software_upload;
    try std.testing.expectEqual(expected, interop.kind);
    const caps = interop.capabilities();
    try std.testing.expectEqual(mac_caps.zero_copy, caps.zero_copy);
}

test "selection parser maps known backend values" {
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode(null));
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode("auto"));
    try std.testing.expectEqual(SelectionMode.force_software, VideoInterop.parseSelectionMode("software"));
    try std.testing.expectEqual(SelectionMode.force_zero_copy, VideoInterop.parseSelectionMode("zero_copy"));
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode("unknown"));
}

test "force software mode never selects zero-copy backend" {
    var interop = VideoInterop.init(.force_software);
    defer interop.deinit();
    try std.testing.expectEqual(BackendKind.software_upload, interop.kind);
}

test "interop falls back to software after repeated backend failures" {
    var interop = VideoInterop.init(.auto);
    defer interop.deinit();

    if (interop.kind != .macos_videotoolbox) {
        return;
    }

    interop.mac_backend.deinit();

    const frame = SoftwareUploadBackendMod.SoftwarePlaneFrame{
        .planes = .{ null, null, null },
        .linesizes = .{ 0, 0, 0 },
        .plane_count = 1,
        .width = 1,
        .height = 1,
        .format = 0,
        .pts = 0.0,
    };

    interop.submitDecodedFrame(frame);
    interop.submitDecodedFrame(frame);
    interop.submitDecodedFrame(frame);

    try std.testing.expectEqual(BackendKind.software_upload, interop.kind);
    try std.testing.expect(interop.fallback_switches >= 1);
}

test "interop diagnostics default to disabled" {
    try std.testing.expect(!VideoInterop.diagnosticsEnabled());
}
