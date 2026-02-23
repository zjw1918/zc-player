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
    interop_handle: bool,
    true_zero_copy: bool,
    supports_nv12: bool,
    supports_yuv420p: bool,
};

pub const InitError = error{UnsupportedZeroCopy};

pub const RuntimeStatus = enum {
    software,
    interop_handle,
    true_zero_copy,
    force_zero_copy_blocked,
};

pub fn initErrorReason(err: InitError) []const u8 {
    return switch (err) {
        error.UnsupportedZeroCopy => "force_zero_copy requested, but true zero-copy backend is not available on this platform/runtime",
    };
}

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
    force_zero_copy_blocked: bool,

    pub fn init(mode: SelectionMode) InitError!VideoInterop {
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
            .force_zero_copy_blocked = false,
        };
        interop.software.init();
        interop.mac_backend.init();
        interop.kind = interop.resolveBackendKind() catch |err| {
            interop.force_zero_copy_blocked = err == error.UnsupportedZeroCopy;
            return err;
        };
        return interop;
    }

    fn resolveBackendKind(self: *const VideoInterop) InitError!BackendKind {
        const mac_caps = self.mac_backend.capabilities();
        return switch (self.mode) {
            .force_software => .software_upload,
            .force_zero_copy => if (mac_caps.true_zero_copy) .macos_videotoolbox else error.UnsupportedZeroCopy,
            .auto => if (mac_caps.interop_handle) .macos_videotoolbox else .software_upload,
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
            if (self.mode == .force_zero_copy) {
                return;
            }
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

    pub fn runtimeStatus(self: *const VideoInterop) RuntimeStatus {
        if (self.force_zero_copy_blocked) {
            return .force_zero_copy_blocked;
        }

        if (self.kind == .macos_videotoolbox) {
            const caps = self.mac_backend.capabilities();
            return if (caps.true_zero_copy) .true_zero_copy else .interop_handle;
        }

        return .software;
    }

    pub fn capabilities(self: *const VideoInterop) Capabilities {
        const caps = switch (self.kind) {
            .software_upload => self.software.capabilities(),
            .macos_videotoolbox => blk: {
                const mac_caps = self.mac_backend.capabilities();
                break :blk SoftwareUploadBackendMod.Capabilities{
                    .interop_handle = mac_caps.interop_handle,
                    .true_zero_copy = mac_caps.true_zero_copy,
                    .supports_nv12 = mac_caps.supports_nv12,
                    .supports_yuv420p = mac_caps.supports_yuv420p,
                };
            },
        };
        return .{
            .interop_handle = caps.interop_handle,
            .true_zero_copy = caps.true_zero_copy,
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
    var interop = try VideoInterop.init(.auto);
    defer interop.deinit();

    const mac_caps = interop.mac_backend.capabilities();
    const expected: BackendKind = if (mac_caps.interop_handle) .macos_videotoolbox else .software_upload;
    try std.testing.expectEqual(expected, interop.kind);
    const caps = interop.capabilities();
    try std.testing.expectEqual(mac_caps.interop_handle, caps.interop_handle);
}

test "selection parser maps known backend values" {
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode(null));
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode("auto"));
    try std.testing.expectEqual(SelectionMode.force_software, VideoInterop.parseSelectionMode("software"));
    try std.testing.expectEqual(SelectionMode.force_zero_copy, VideoInterop.parseSelectionMode("zero_copy"));
    try std.testing.expectEqual(SelectionMode.auto, VideoInterop.parseSelectionMode("unknown"));
}

test "force software mode never selects zero-copy backend" {
    var interop = try VideoInterop.init(.force_software);
    defer interop.deinit();
    try std.testing.expectEqual(BackendKind.software_upload, interop.kind);
}

test "force zero-copy mode fails fast when true zero-copy unsupported" {
    if (VideoInterop.init(.force_zero_copy)) |_| {
        return;
    } else |err| {
        try std.testing.expectEqual(error.UnsupportedZeroCopy, err);
    }
}

test "interop falls back to software after repeated backend failures" {
    var interop = try VideoInterop.init(.auto);
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
        .source_hw = false,
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

test "unsupported zero-copy error has explicit reason" {
    try std.testing.expect(std.mem.indexOf(u8, initErrorReason(error.UnsupportedZeroCopy), "force_zero_copy") != null);
}
