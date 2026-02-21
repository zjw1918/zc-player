# zc-player

`zc-player` is a desktop video player built with Zig, Vulkan, SDL3, ImGui, and FFmpeg.

## Highlights

- Vulkan-based video rendering pipeline
- Zig application/runtime and playback orchestration
- Native UI/rendering layer in C/C++ (SDL3 + ImGui + Vulkan)
- Single media backend (Zig-exported media implementation)

## Project Layout

- `src/` Zig application, engine, media, and FFI modules
- `native/src/` native windowing, Vulkan renderer, and ImGui integration
- `src/shaders/` GLSL shaders and generated SPIR-V artifacts

## Prerequisites

- Zig `0.15.2+`
- `glslc` available on `PATH`
- System libraries: `SDL3`, `vulkan`, `avformat`, `avcodec`, `swscale`, `swresample`, `avutil`

## Build and Run

- Build: `zig build`
- Build (ReleaseFast): `zig build -Doptimize=ReleaseFast`
- Run: `zig build run`
- Run with media file: `zig build run -- /path/to/media.mp4`

## Tests

- Run all tests: `zig build test`
- Run tests (ReleaseFast): `zig build test -Doptimize=ReleaseFast`
- Run a filtered test:
  - `zig build test -- --test-filter "engine start and scalar commands"`

## Shaders

- Compile shaders explicitly: `zig build compile-shaders`
- App build already depends on shader compilation.
