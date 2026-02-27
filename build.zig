const std = @import("std");

fn configureNativeDeps(b: *std.Build, step: *std.Build.Step.Compile) void {
    const third_party = "third_party";

    step.addIncludePath(b.path("native/src"));
    step.addIncludePath(b.path("native/src/player"));
    step.addIncludePath(b.path("native/src/video"));
    step.addIncludePath(b.path("native/src/audio"));
    step.addIncludePath(b.path("third_party/imgui"));
    step.addIncludePath(b.path("third_party/imgui/backends"));

    const sdl3_base = b.pathJoin(&.{ third_party, "sdl3", "3.4.2", "SDL3-3.4.2", "x86_64-w64-mingw32" });
    step.addIncludePath(b.path(b.pathJoin(&.{ sdl3_base, "include" })));
    step.addLibraryPath(b.path(b.pathJoin(&.{ sdl3_base, "lib" })));

    const ffmpeg_base = b.pathJoin(&.{ third_party, "ffmpeg", "n8.0-latest", "ffmpeg-n8.0-latest-win64-gpl-shared-8.0" });
    step.addIncludePath(b.path(b.pathJoin(&.{ ffmpeg_base, "include" })));
    step.addLibraryPath(b.path(b.pathJoin(&.{ ffmpeg_base, "lib" })));

    const vulkan_sdk = std.process.getEnvVarOwned(b.allocator, "VULKAN_SDK") catch null;
    if (vulkan_sdk) |vk| {
        defer b.allocator.free(vk);
        const vulkan_include = std.fmt.allocPrint(b.allocator, "{s}/include", .{vk}) catch return;
        defer b.allocator.free(vulkan_include);
        step.addSystemIncludePath(.{ .cwd_relative = vulkan_include });
        const vulkan_lib = std.fmt.allocPrint(b.allocator, "{s}/lib", .{vk}) catch return;
        defer b.allocator.free(vulkan_lib);
        step.addLibraryPath(.{ .cwd_relative = vulkan_lib });
    } else {
        step.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    }

    step.addCSourceFiles(.{
        .files = &.{
            "native/src/app/app.c",
            "native/src/renderer/renderer.c",
            "native/src/renderer/apple_interop_bridge.mm",
            "native/src/ui/ui.cpp",
            "third_party/imgui/imgui.cpp",
            "third_party/imgui/imgui_draw.cpp",
            "third_party/imgui/imgui_tables.cpp",
            "third_party/imgui/imgui_widgets.cpp",
            "third_party/imgui/backends/imgui_impl_sdl3.cpp",
            "third_party/imgui/backends/imgui_impl_vulkan.cpp",
        },
    });

    step.linkLibCpp();

    step.linkSystemLibrary("SDL3");
    step.linkSystemLibrary("vulkan");
    step.linkSystemLibrary("avformat");
    step.linkSystemLibrary("avcodec");
    step.linkSystemLibrary("swscale");
    step.linkSystemLibrary("swresample");
    step.linkSystemLibrary("avutil");

    if (step.rootModuleTarget().os.tag == .macos) {
        step.linkFramework("Metal");
        step.linkFramework("CoreVideo");
        step.linkFramework("QuartzCore");
        step.linkFramework("Foundation");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ffmpeg_base = b.pathJoin(&.{ "third_party", "ffmpeg", "n8.0-latest", "ffmpeg-n8.0-latest-win64-gpl-shared-8.0" });

    const fetch_third_party_cmd = b.addSystemCommand(&.{ "zig", "run", "scripts/fetch_third_party.zig", "--" });
    const fetch_third_party_step = b.step("fetch-third-party", "Fetch third-party dependencies for development");
    fetch_third_party_step.dependOn(&fetch_third_party_cmd.step);

    const compile_shader_step = b.step("compile-shaders", "Compile Vulkan shaders to SPIR-V");

    const vert_spv = b.addSystemCommand(&.{ "glslc", "-o", "src/shaders/video.vert.spv", "src/shaders/video.vert" });
    compile_shader_step.dependOn(&vert_spv.step);

    const frag_spv = b.addSystemCommand(&.{ "glslc", "-o", "src/shaders/video.frag.spv", "src/shaders/video.frag" });
    compile_shader_step.dependOn(&frag_spv.step);

    const exe = b.addExecutable(.{
        .name = "zc-player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureNativeDeps(b, exe);
    exe.step.dependOn(&vert_spv.step);
    exe.step.dependOn(&frag_spv.step);

    b.installArtifact(exe);

    const ffmpeg_dlls = [_][]const u8{
        "avcodec-62.dll",
        "avdevice-62.dll",
        "avfilter-11.dll",
        "avformat-62.dll",
        "avutil-60.dll",
        "swresample-6.dll",
        "swscale-9.dll",
    };
    for (ffmpeg_dlls) |dll_name| {
        const dll_path = b.pathJoin(&.{ ffmpeg_base, "bin", dll_name });
        _ = b.addInstallBinFile(b.path(dll_path), dll_name);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPathDir(b.pathJoin(&.{ ffmpeg_base, "bin" }));
    run_cmd.addPathDir(b.pathJoin(&.{ "third_party", "sdl3", "3.4.2", "SDL3-3.4.2", "x86_64-w64-mingw32", "bin" }));

    const run_step = b.step("run", "Run zc-player");
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
        fetch_third_party_cmd.addArgs(args);
    }

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureNativeDeps(b, unit_tests);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.addPathDir(b.pathJoin(&.{ ffmpeg_base, "bin" }));
    run_unit_tests.addPathDir(b.pathJoin(&.{ "third_party", "sdl3", "3.4.2", "SDL3-3.4.2", "x86_64-w64-mingw32", "bin" }));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
