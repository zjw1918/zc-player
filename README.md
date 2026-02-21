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

## Developer Setup

- Bootstrap third-party dependencies (host defaults):
  - `zig build fetch-third-party`
- Fetch SDL3 for a specific target from the latest release:
  - `zig build fetch-third-party -- --target windows-x64`
- Pin an SDL3 release version:
  - `zig build fetch-third-party -- --version X.Y.Z --target macos`

The setup script:

- Clones ImGui into `third_party/imgui` when missing.
- Downloads one SDL3 release artifact into `third_party/sdl3/<version>/`.
- Supports targets: `host`, `windows-x64`, `windows-x86`, `windows-arm64`, `macos`, `linux-src`.
- Requires `git` and `curl` on `PATH`.

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
