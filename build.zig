const std = @import("std");

fn configureNativeDeps(b: *std.Build, step: *std.Build.Step.Compile) void {
    step.addIncludePath(b.path("native/src"));
    step.addIncludePath(b.path("native/src/player"));
    step.addIncludePath(b.path("native/src/video"));
    step.addIncludePath(b.path("native/src/audio"));
    step.addIncludePath(b.path("third_party/imgui"));
    step.addIncludePath(b.path("third_party/imgui/backends"));
    step.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

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

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
