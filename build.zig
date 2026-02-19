const std = @import("std");

fn configureNativeDeps(b: *std.Build, step: *std.Build.Step.Compile, use_zig_media: bool) void {
    step.addIncludePath(b.path("native/src"));
    step.addIncludePath(b.path("native/src/player"));
    step.addIncludePath(b.path("native/src/video"));
    step.addIncludePath(b.path("native/src/audio"));
    step.addIncludePath(b.path("third_party/imgui"));
    step.addIncludePath(b.path("third_party/imgui/backends"));
    step.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });

    if (!use_zig_media) {
        step.addCSourceFiles(.{
            .files = &.{
                "native/archive-c/player/player.c",
                "native/archive-c/player/demuxer.c",
                "native/archive-c/video/video_decoder.c",
                "native/archive-c/video/video_pipeline.c",
                "native/archive-c/audio/audio_decoder.c",
                "native/archive-c/audio/audio_output.c",
            },
        });
    }

    step.addCSourceFiles(.{
        .files = &.{
            "native/src/app/app.c",
            "native/src/renderer/renderer.c",
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
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const media_impl = b.option([]const u8, "media_impl", "Media implementation: c or zig") orelse "c";
    const use_zig_media = blk: {
        if (std.mem.eql(u8, media_impl, "zig")) break :blk true;
        if (std.mem.eql(u8, media_impl, "c")) break :blk false;
        std.debug.panic("invalid -Dmedia_impl value: {s} (expected c or zig)", .{media_impl});
    };

    const options = b.addOptions();
    options.addOption(bool, "media_impl_zig", use_zig_media);

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
    exe.root_module.addOptions("build_options", options);
    configureNativeDeps(b, exe, use_zig_media);
    exe.step.dependOn(&vert_spv.step);
    exe.step.dependOn(&frag_spv.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zc-player");
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("build_options", options);
    configureNativeDeps(b, unit_tests, use_zig_media);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
