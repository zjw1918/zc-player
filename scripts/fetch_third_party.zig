const builtin = @import("builtin");
const std = @import("std");

const github_accept_header = "Accept: application/vnd.github+json";
const github_user_agent_header = "User-Agent: zc-player-bootstrap";
const sdl_release_api = "https://api.github.com/repos/libsdl-org/SDL/releases";
const ffmpeg_release_api = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases";
const imgui_repo = "https://github.com/ocornut/imgui.git";

pub const Target = enum {
    host,
    windows_x64,
    windows_x86,
    windows_arm64,
    macos,
    linux_src,
};

const Asset = struct {
    name: []const u8,
    url: []const u8,
};

const Config = struct {
    target: Target = .host,
    version: []const u8 = "latest",
    third_party_dir: []const u8 = "third_party",
    skip_imgui: bool = false,
    skip_sdl3: bool = false,
    skip_ffmpeg: bool = false,
    force: bool = false,
    help: bool = false,
};

const ReleaseAsset = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const ReleaseResponse = struct {
    tag_name: []const u8,
    assets: []const ReleaseAsset,
};

const ParsedRelease = struct {
    version: []u8,
    asset_name: []u8,
    asset_url: []u8,

    fn deinit(self: *ParsedRelease, allocator: std.mem.Allocator) void {
        allocator.free(self.version);
        allocator.free(self.asset_name);
        allocator.free(self.asset_url);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(args);

    if (config.help) {
        printHelp();
        return;
    }

    try std.fs.cwd().makePath(config.third_party_dir);

    if (!config.skip_imgui) {
        try ensureImgui(allocator, config.third_party_dir);
    }

    if (!config.skip_sdl3) {
        try fetchSdl3(allocator, config);
    }

    if (!config.skip_ffmpeg) {
        try fetchFfmpeg(allocator, config);
    }

    std.debug.print("Bootstrap complete.\n", .{});
}

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-imgui")) {
            config.skip_imgui = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-sdl3")) {
            config.skip_sdl3 = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--skip-ffmpeg")) {
            config.skip_ffmpeg = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--force")) {
            config.force = true;
            continue;
        }

        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingTarget;
            config.target = try parseTarget(args[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            i += 1;
            if (i >= args.len) return error.MissingVersion;
            config.version = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--third-party-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingThirdPartyDir;
            config.third_party_dir = args[i];
            continue;
        }

        return error.InvalidArgument;
    }

    return config;
}

fn parseTarget(value: []const u8) !Target {
    if (std.mem.eql(u8, value, "host")) return .host;
    if (std.mem.eql(u8, value, "windows-x64")) return .windows_x64;
    if (std.mem.eql(u8, value, "windows-x86")) return .windows_x86;
    if (std.mem.eql(u8, value, "windows-arm64")) return .windows_arm64;
    if (std.mem.eql(u8, value, "macos")) return .macos;
    if (std.mem.eql(u8, value, "linux-src")) return .linux_src;
    return error.InvalidTarget;
}

fn resolveHostTarget(os_tag: std.Target.Os.Tag, cpu_arch: std.Target.Cpu.Arch) !Target {
    switch (os_tag) {
        .windows => switch (cpu_arch) {
            .x86_64 => return .windows_x64,
            .x86 => return .windows_x86,
            .aarch64 => return .windows_arm64,
            else => return error.UnsupportedHost,
        },
        .macos => switch (cpu_arch) {
            .x86_64, .aarch64 => return .macos,
            else => return error.UnsupportedHost,
        },
        .linux => return .linux_src,
        else => return error.UnsupportedHost,
    }
}

fn normalizeVersionFromTag(tag: []const u8) []const u8 {
    if (std.mem.startsWith(u8, tag, "release-")) {
        return tag["release-".len..];
    }
    if (std.mem.startsWith(u8, tag, "v") and tag.len > 1) {
        return tag[1..];
    }
    return tag;
}

fn targetAssetMatches(name: []const u8, target: Target) bool {
    return switch (target) {
        .host => false,
        .windows_x64 => std.mem.startsWith(u8, name, "SDL3-") and std.mem.endsWith(u8, name, "-win32-x64.zip"),
        .windows_x86 => std.mem.startsWith(u8, name, "SDL3-") and std.mem.endsWith(u8, name, "-win32-x86.zip"),
        .windows_arm64 => std.mem.startsWith(u8, name, "SDL3-") and std.mem.endsWith(u8, name, "-win32-arm64.zip"),
        .macos => std.mem.startsWith(u8, name, "SDL3-") and std.mem.endsWith(u8, name, ".dmg"),
        .linux_src => std.mem.startsWith(u8, name, "SDL3-") and
            std.mem.endsWith(u8, name, ".tar.gz") and
            std.mem.indexOf(u8, name, "-mingw") == null and
            std.mem.indexOf(u8, name, "-devel-") == null,
    };
}

fn selectAssetByTarget(assets: []const Asset, target: Target) ?Asset {
    for (assets) |asset| {
        if (targetAssetMatches(asset.name, target)) {
            return asset;
        }
    }
    return null;
}

fn selectReleaseAssetByTarget(assets: []const ReleaseAsset, target: Target) ?ReleaseAsset {
    for (assets) |asset| {
        if (targetAssetMatches(asset.name, target)) {
            return asset;
        }
    }
    return null;
}

fn ffmpegTargetAssetMatches(name: []const u8, target: Target) bool {
    return switch (target) {
        .host => false,
        .windows_x64 => std.mem.startsWith(u8, name, "ffmpeg-") and
            std.mem.indexOf(u8, name, "-win64-gpl-shared") != null and
            std.mem.endsWith(u8, name, ".zip"),
        .windows_x86 => false,
        .windows_arm64 => std.mem.startsWith(u8, name, "ffmpeg-") and
            std.mem.indexOf(u8, name, "-winarm64-gpl-shared") != null and
            std.mem.endsWith(u8, name, ".zip"),
        .macos => false,
        .linux_src => false,
    };
}

fn ffmpegAssetRank(name: []const u8) i32 {
    if (std.mem.startsWith(u8, name, "ffmpeg-n8.")) return 300;
    if (std.mem.startsWith(u8, name, "ffmpeg-n7.")) return 200;
    if (std.mem.indexOf(u8, name, "master") != null) return 100;
    return 10;
}

fn sdl3DevelAssetMatches(name: []const u8, target: Target) bool {
    return switch (target) {
        .host => false,
        .windows_x64 => std.mem.startsWith(u8, name, "SDL3-") and std.mem.endsWith(u8, name, "-mingw.zip"),
        .windows_x86 => false,
        .windows_arm64 => false,
        .macos => false,
        .linux_src => false,
    };
}

fn selectFfmpegAssetByTarget(assets: []const ReleaseAsset, target: Target) ?ReleaseAsset {
    var selected: ?ReleaseAsset = null;
    var best_rank: i32 = -1;

    for (assets) |asset| {
        if (ffmpegTargetAssetMatches(asset.name, target)) {
            const rank = ffmpegAssetRank(asset.name);
            if (rank > best_rank) {
                selected = asset;
                best_rank = rank;
            }
        }
    }

    return selected;
}

fn pathExists(path: []const u8) !bool {
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn ensureImgui(allocator: std.mem.Allocator, third_party_dir: []const u8) !void {
    const imgui_header = try std.fs.path.join(allocator, &.{ third_party_dir, "imgui", "imgui.h" });
    defer allocator.free(imgui_header);

    if (try pathExists(imgui_header)) {
        std.debug.print("ImGui already present at {s}.\n", .{imgui_header});
        return;
    }

    const imgui_dir = try std.fs.path.join(allocator, &.{ third_party_dir, "imgui" });
    defer allocator.free(imgui_dir);

    if (try pathExists(imgui_dir)) {
        std.log.err("{s} exists but does not look like a valid ImGui checkout.", .{imgui_dir});
        return error.InvalidImguiDirectory;
    }

    std.debug.print("Cloning ImGui into {s}...\n", .{imgui_dir});
    try runCommandNoCapture(allocator, &.{
        "git",
        "clone",
        "--depth",
        "1",
        imgui_repo,
        imgui_dir,
    });
}

fn fetchSdl3(allocator: std.mem.Allocator, config: Config) !void {
    const target = switch (config.target) {
        .host => try resolveHostTarget(builtin.os.tag, builtin.cpu.arch),
        else => config.target,
    };

    const release_json = try fetchReleaseJson(allocator, config.version);
    defer allocator.free(release_json);

    var release = try parseReleaseForTarget(allocator, release_json, target);
    defer release.deinit(allocator);

    const out_dir = try std.fs.path.join(allocator, &.{ config.third_party_dir, "sdl3", release.version });
    defer allocator.free(out_dir);
    try std.fs.cwd().makePath(out_dir);

    const output_path = try std.fs.path.join(allocator, &.{ out_dir, release.asset_name });
    defer allocator.free(output_path);

    if (!config.force and try pathExists(output_path)) {
        std.debug.print("SDL3 artifact already present at {s} (use --force to redownload).\n", .{output_path});
        return;
    }

    std.debug.print("Downloading SDL3 {s} asset {s}...\n", .{ release.version, release.asset_name });
    try runCommandNoCapture(allocator, &.{
        "curl",
        "-fL",
        "--retry",
        "3",
        "--retry-delay",
        "1",
        "-H",
        github_accept_header,
        "-H",
        github_user_agent_header,
        "-o",
        output_path,
        release.asset_url,
    });

    std.debug.print("Saved SDL3 artifact to {s}.\n", .{output_path});

    try extractArchiveForTarget(allocator, output_path, out_dir, target);

    try fetchSdl3Devel(allocator, config, target, out_dir);
}

fn fetchSdl3Devel(allocator: std.mem.Allocator, config: Config, target: Target, out_dir: []const u8) !void {
    const release_json = try fetchReleaseJson(allocator, config.version);
    defer allocator.free(release_json);

    var parsed = try std.json.parseFromSlice(ReleaseResponse, allocator, release_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const selected = for (parsed.value.assets) |asset| {
        if (sdl3DevelAssetMatches(asset.name, target)) break asset;
    } else return;

    const devel_asset_name = try allocator.dupe(u8, selected.name);
    defer allocator.free(devel_asset_name);
    const devel_asset_url = try allocator.dupe(u8, selected.browser_download_url);
    defer allocator.free(devel_asset_url);

    const output_path = try std.fs.path.join(allocator, &.{ out_dir, devel_asset_name });
    defer allocator.free(output_path);

    if (!config.force and try pathExists(output_path)) {
        std.debug.print("SDL3 devel artifact already present at {s}.\n", .{output_path});
        return;
    }

    std.debug.print("Downloading SDL3 devel asset {s}...\n", .{devel_asset_name});
    try runCommandNoCapture(allocator, &.{
        "curl",
        "-fL",
        "--retry",
        "3",
        "--retry-delay",
        "1",
        "-H",
        github_accept_header,
        "-H",
        github_user_agent_header,
        "-o",
        output_path,
        devel_asset_url,
    });

    std.debug.print("Saved SDL3 devel artifact to {s}.\n", .{output_path});
    try extractZip(allocator, output_path, out_dir);
}

fn fetchFfmpeg(allocator: std.mem.Allocator, config: Config) !void {
    const target = switch (config.target) {
        .host => try resolveHostTarget(builtin.os.tag, builtin.cpu.arch),
        else => config.target,
    };

    const release_json = try fetchFfmpegReleaseJson(allocator, config.version);
    defer allocator.free(release_json);

    var release = parseFfmpegReleaseForTarget(allocator, release_json, target) catch |err| switch (err) {
        error.AssetNotFound => {
            std.debug.print("No FFmpeg asset available for target {s}; skipping.\n", .{@tagName(target)});
            return;
        },
        else => return err,
    };
    defer release.deinit(allocator);

    const out_dir = try std.fs.path.join(allocator, &.{ config.third_party_dir, "ffmpeg", release.version });
    defer allocator.free(out_dir);
    try std.fs.cwd().makePath(out_dir);

    const output_path = try std.fs.path.join(allocator, &.{ out_dir, release.asset_name });
    defer allocator.free(output_path);

    if (!config.force and try pathExists(output_path)) {
        std.debug.print("FFmpeg artifact already present at {s} (use --force to redownload).\n", .{output_path});
        return;
    }

    std.debug.print("Downloading FFmpeg {s} asset {s}...\n", .{ release.version, release.asset_name });
    try runCommandNoCapture(allocator, &.{
        "curl",
        "-fL",
        "--retry",
        "3",
        "--retry-delay",
        "1",
        "-H",
        github_accept_header,
        "-H",
        github_user_agent_header,
        "-o",
        output_path,
        release.asset_url,
    });

    std.debug.print("Saved FFmpeg artifact to {s}.\n", .{output_path});

    try extractArchiveForTarget(allocator, output_path, out_dir, target);
}

fn extractZip(allocator: std.mem.Allocator, archive_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("Extracting {s} to {s}...\n", .{ archive_path, out_dir });

    switch (builtin.os.tag) {
        .windows => try runCommandNoCapture(allocator, &.{ "powershell", "-Command", "Expand-Archive", "-Path", archive_path, "-DestinationPath", out_dir, "-Force" }),
        else => try runCommandNoCapture(allocator, &.{ "unzip", "-oq", archive_path, "-d", out_dir }),
    }

    std.debug.print("Extraction complete.\n", .{});
}

fn extractTarXz(allocator: std.mem.Allocator, archive_path: []const u8, out_dir: []const u8) !void {
    std.debug.print("Extracting {s} to {s}...\n", .{ archive_path, out_dir });
    try runCommandNoCapture(allocator, &.{ "tar", "-xf", archive_path, "-C", out_dir });
    std.debug.print("Extraction complete.\n", .{});
}

fn extractArchiveForTarget(allocator: std.mem.Allocator, archive_path: []const u8, out_dir: []const u8, target: Target) !void {
    if (std.mem.endsWith(u8, archive_path, ".zip")) {
        try extractZip(allocator, archive_path, out_dir);
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".tar.gz") or std.mem.endsWith(u8, archive_path, ".tar.xz")) {
        try extractTarXz(allocator, archive_path, out_dir);
        return;
    }

    if (std.mem.endsWith(u8, archive_path, ".dmg") and target == .macos) {
        std.debug.print("Downloaded DMG at {s}. Please install/mount manually on macOS.\n", .{archive_path});
        return;
    }

    return error.UnsupportedArchiveType;
}

fn parseReleaseForTarget(allocator: std.mem.Allocator, release_json: []const u8, target: Target) !ParsedRelease {
    var parsed = try std.json.parseFromSlice(ReleaseResponse, allocator, release_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const selected = selectReleaseAssetByTarget(parsed.value.assets, target) orelse return error.AssetNotFound;
    return .{
        .version = try allocator.dupe(u8, normalizeVersionFromTag(parsed.value.tag_name)),
        .asset_name = try allocator.dupe(u8, selected.name),
        .asset_url = try allocator.dupe(u8, selected.browser_download_url),
    };
}

fn fetchReleaseJson(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    if (std.mem.eql(u8, version, "latest")) {
        const url = sdl_release_api ++ "/latest";
        return curlGet(allocator, url);
    }

    const prefixed = try std.fmt.allocPrint(allocator, "release-{s}", .{version});
    defer allocator.free(prefixed);

    const prefixed_url = try std.fmt.allocPrint(allocator, "{s}/tags/{s}", .{ sdl_release_api, prefixed });
    defer allocator.free(prefixed_url);

    const prefixed_json = curlGet(allocator, prefixed_url) catch |err| switch (err) {
        error.CommandFailed => null,
        else => return err,
    };
    if (prefixed_json) |json| return json;

    const raw_url = try std.fmt.allocPrint(allocator, "{s}/tags/{s}", .{ sdl_release_api, version });
    defer allocator.free(raw_url);

    return curlGet(allocator, raw_url) catch |err| switch (err) {
        error.CommandFailed => error.ReleaseNotFound,
        else => err,
    };
}

fn fetchFfmpegReleaseJson(allocator: std.mem.Allocator, version: []const u8) ![]u8 {
    if (std.mem.eql(u8, version, "latest")) {
        const url = ffmpeg_release_api ++ "/latest";
        return curlGet(allocator, url);
    }

    const prefixed_url = try std.fmt.allocPrint(allocator, "{s}/tags/{s}", .{ ffmpeg_release_api, version });
    defer allocator.free(prefixed_url);

    return curlGet(allocator, prefixed_url) catch |err| switch (err) {
        error.CommandFailed => error.ReleaseNotFound,
        else => err,
    };
}

fn parseFfmpegReleaseForTarget(allocator: std.mem.Allocator, release_json: []const u8, target: Target) !ParsedRelease {
    var parsed = try std.json.parseFromSlice(ReleaseResponse, allocator, release_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const selected = selectFfmpegAssetByTarget(parsed.value.assets, target) orelse return error.AssetNotFound;
    return .{
        .version = try allocator.dupe(u8, normalizeVersionFromTag(parsed.value.tag_name)),
        .asset_name = try allocator.dupe(u8, selected.name),
        .asset_url = try allocator.dupe(u8, selected.browser_download_url),
    };
}

fn runCommandNoCapture(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
            std.log.err("command failed with exit code {d}: {s}", .{ code, argv[0] });
            if (result.stderr.len > 0) {
                std.log.err("stderr: {s}", .{result.stderr});
            }
            return error.CommandFailed;
        },
        else => return error.CommandFailed,
    }
}

fn curlGet(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 1024 * 1024 * 10,
        .argv = &.{
            "curl",
            "-fsSL",
            "-H",
            github_accept_header,
            "-H",
            github_user_agent_header,
            url,
        },
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return result.stdout;
            }
            allocator.free(result.stdout);
            if (result.stderr.len > 0) {
                std.log.err("curl failed for {s}: {s}", .{ url, result.stderr });
            }
            return error.CommandFailed;
        },
        else => {
            allocator.free(result.stdout);
            return error.CommandFailed;
        },
    }
}

fn printHelp() void {
    std.debug.print(
        \\Fetch third-party dependencies required for zc-player development.
        \\
        \\Usage:
        \\  zig run scripts/fetch_third_party.zig -- [options]
        \\
        \\Options:
        \\  --target <host|windows-x64|windows-x86|windows-arm64|macos|linux-src>
        \\  --version <latest|X.Y.Z>
        \\  --third-party-dir <path>
        \\  --skip-imgui
        \\  --skip-sdl3
        \\  --skip-ffmpeg
        \\  --force
        \\  --help
        \\
        \\Examples:
        \\  zig run scripts/fetch_third_party.zig --
        \\  zig run scripts/fetch_third_party.zig -- --target windows-x64
        \\  zig run scripts/fetch_third_party.zig -- --version X.Y.Z --target macos
        \\  zig run scripts/fetch_third_party.zig -- --skip-imgui
        \\
    , .{});
}

test "parseTarget accepts explicit targets" {
    try std.testing.expectEqual(Target.windows_x64, try parseTarget("windows-x64"));
    try std.testing.expectEqual(Target.windows_x86, try parseTarget("windows-x86"));
    try std.testing.expectEqual(Target.windows_arm64, try parseTarget("windows-arm64"));
    try std.testing.expectEqual(Target.macos, try parseTarget("macos"));
    try std.testing.expectEqual(Target.linux_src, try parseTarget("linux-src"));
    try std.testing.expectEqual(Target.host, try parseTarget("host"));
}

test "resolveHostTarget maps supported hosts" {
    try std.testing.expectEqual(Target.windows_x64, try resolveHostTarget(.windows, .x86_64));
    try std.testing.expectEqual(Target.windows_x86, try resolveHostTarget(.windows, .x86));
    try std.testing.expectEqual(Target.windows_arm64, try resolveHostTarget(.windows, .aarch64));
    try std.testing.expectEqual(Target.macos, try resolveHostTarget(.macos, .x86_64));
    try std.testing.expectEqual(Target.macos, try resolveHostTarget(.macos, .aarch64));
    try std.testing.expectEqual(Target.linux_src, try resolveHostTarget(.linux, .x86_64));
}

test "normalizeVersionFromTag strips release prefix" {
    try std.testing.expectEqualStrings("3.4.2", normalizeVersionFromTag("release-3.4.2"));
    try std.testing.expectEqualStrings("3.4.2", normalizeVersionFromTag("3.4.2"));
    try std.testing.expectEqualStrings("3.4.2", normalizeVersionFromTag("v3.4.2"));
}

test "selectAssetByTarget chooses matching SDL3 artifact" {
    const assets = [_]Asset{
        .{ .name = "SDL3-3.4.2-win32-x64.zip", .url = "https://example.test/x64" },
        .{ .name = "SDL3-3.4.2-win32-arm64.zip", .url = "https://example.test/arm64" },
        .{ .name = "SDL3-3.4.2.dmg", .url = "https://example.test/macos" },
        .{ .name = "SDL3-3.4.2.tar.gz", .url = "https://example.test/linux" },
    };

    const win = selectAssetByTarget(&assets, .windows_x64) orelse return error.ExpectedFound;
    try std.testing.expectEqualStrings("SDL3-3.4.2-win32-x64.zip", win.name);

    const mac = selectAssetByTarget(&assets, .macos) orelse return error.ExpectedFound;
    try std.testing.expectEqualStrings("SDL3-3.4.2.dmg", mac.name);

    const linux = selectAssetByTarget(&assets, .linux_src) orelse return error.ExpectedFound;
    try std.testing.expectEqualStrings("SDL3-3.4.2.tar.gz", linux.name);
}

test "parseReleaseForTarget extracts version and url" {
    const json =
        \\{
        \\  "tag_name": "release-3.4.2",
        \\  "assets": [
        \\    {
        \\      "name": "SDL3-3.4.2-win32-x64.zip",
        \\      "browser_download_url": "https://example.test/x64"
        \\    },
        \\    {
        \\      "name": "SDL3-3.4.2.dmg",
        \\      "browser_download_url": "https://example.test/macos"
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseReleaseForTarget(std.testing.allocator, json, .macos);
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("3.4.2", parsed.version);
    try std.testing.expectEqualStrings("SDL3-3.4.2.dmg", parsed.asset_name);
    try std.testing.expectEqualStrings("https://example.test/macos", parsed.asset_url);
}

test "selectFfmpegAssetByTarget prefers n8 over master" {
    const assets = [_]ReleaseAsset{
        .{ .name = "ffmpeg-master-latest-win64-gpl-shared.zip", .browser_download_url = "https://example.test/master" },
        .{ .name = "ffmpeg-n8.0-latest-win64-gpl-shared-8.0.zip", .browser_download_url = "https://example.test/n8" },
        .{ .name = "ffmpeg-n7.1-latest-win64-gpl-shared-7.1.zip", .browser_download_url = "https://example.test/n7" },
    };

    const selected = selectFfmpegAssetByTarget(&assets, .windows_x64) orelse return error.ExpectedFound;
    try std.testing.expectEqualStrings("ffmpeg-n8.0-latest-win64-gpl-shared-8.0.zip", selected.name);
}
