# AGENTS.md
Guidance for coding agents working in this repository.

## Project Overview
- Primary language: Zig (`src/`).
- Native layer: C/C++ (`native/src/`) with SDL3, Vulkan, and FFmpeg.
- Build system: Zig build (`build.zig`).
- Entrypoint: `src/main.zig`.
- Test root module: `src/root.zig`.
- Vendored code: `third_party/imgui/` (avoid edits unless required).

## Layout
- `src/app/` app runtime and GUI orchestration.
- `src/engine/` command queue, thread loop, snapshots.
- `src/media/` player/session control.
- `src/audio/`, `src/video/` media output/pipeline wrappers.
- `src/ffi/` Zig-to-C imports and boundary modules.
- `native/src/` active native code.
- `src/shaders/` GLSL + generated SPIR-V.

## Prerequisites
- Zig `0.15.2`+ (`build.zig.zon` minimum).
- `glslc` available on `PATH`.
- Linkable system libs: `SDL3`, `vulkan`, `avformat`, `avcodec`, `swscale`, `swresample`, `avutil`.
- Build currently adds `/opt/homebrew/include` as system include path.

## Build / Run Commands
- Build app: `zig build`
- Build release-fast: `zig build -Doptimize=ReleaseFast`
- Run app: `zig build run`
- Run app with media file: `zig build run -- /path/to/media.mp4`

## Shader Commands
- Explicit shader compile step: `zig build compile-shaders`
- App build already depends on shader compilation.

## Test Commands
- Run full suite: `zig build test`
- Run tests release-fast: `zig build test -Doptimize=ReleaseFast`

## Running a Single Test
- Preferred via build system:
  - `zig build test -- --test-filter "engine start and scalar commands"`
- Direct Zig test (use only when build-step parity is not needed):
  - `zig test src/engine/PlaybackEngine.zig`

## Lint and Formatting
- No dedicated lint step is defined in `build.zig`.
- Zig formatting command: `zig fmt`.
- Format touched Zig files: `zig fmt build.zig src/**/*.zig`
- Check-only formatting: `zig fmt --check build.zig src/**/*.zig`
- No repo-level C/C++ formatter config is present; preserve existing style.

## Style Guide (Zig)

### Imports
- Keep imports at file top.
- Typical patterns:
  - `const std = @import("std");`
  - `const Foo = @import("path/Foo.zig").Foo;`
  - `const c = @import("../ffi/cplayer.zig").c;`
- Use aliases for nested type modules (`SnapshotMod`, `CommandMod`) when helpful.

### Formatting
- Always run `zig fmt` after edits.
- Use formatter output as source of truth.
- Prefer short guard clauses and early returns.

### Naming
- Types, structs, enums: `PascalCase` (`PlaybackEngine`).
- Functions/methods/locals: `camelCase` (`sendSeekAbs`, `media_path`).
- Internal constants: `snake_case` (`queue_capacity`, `tick_ns`).
- Keep existing FFI constant names from C headers.

### Types and APIs
- Use explicit types for public fields/functions.
- Use `!T` for fallible APIs.
- Use `?T` for optional data.
- Keep raw C pointers/handles inside wrapper structs near FFI boundary.

### Error Handling
- Translate native failures into Zig errors (`error.InitFailed`, etc.).
- Use `try` for required operations.
- Use `catch return`/`catch {}` only when failure is intentionally non-fatal.
- Preserve existing best-effort UI command behavior.
- Avoid panics for recoverable runtime conditions.

### Resources and Lifetime
- Pair init/deinit consistently.
- Use `defer` immediately after successful acquisition.
- On partial native init failure, unwind and clean up in reverse order.
- Keep ownership explicit in struct fields.

### Concurrency
- Protect shared mutable state with mutexes.
- Use atomics for run-state signaling.
- Use condition variables for queue wakeups.
- Keep lock scope tight around state mutation.

## Style Guide (Native C/C++)
- Follow file-local existing style; do not reformat unrelated lines.
- Use `snake_case` function names and `static` helpers for internal functions.
- Keep success/failure return convention (`0` success, non-zero failure).
- Preserve explicit error logging via `fprintf(stderr, ...)` where already used.
- Do not introduce C++ abstractions into `.c` files.

## FFI Boundary Rules
- Keep `@cImport` isolated in `src/ffi/*.zig` files.
- Expose thin Zig wrappers around raw C APIs.
- Convert C-style booleans/ints to Zig booleans/errors at the boundary.
- Preserve ABI-sensitive function signatures and call conventions.

## Testing Guidance
- Add tests close to the module being changed.
- Prefer deterministic tests with minimal sleep/timing.
- Use `std.testing.expect` and related helpers.
- If runtime dependencies are unavailable, still verify compile path when possible.

## Generated Artifacts
- `src/shaders/*.spv` are generated artifacts.
- Rebuild shaders after `.vert`/`.frag` changes.
- Do not treat generated `.spv` as hand-edited source.

## Cursor/Copilot Rules
- No `.cursor/rules/` directory found.
- No `.cursorrules` file found.
- No `.github/copilot-instructions.md` found.
- If these files appear later, treat them as higher-priority instructions.

## Agent Checklist
- Read `build.zig` before changing build behavior.
- Keep edits focused; avoid drive-by refactors.
- Run `zig fmt` on touched Zig files.
- Run a targeted test filter first, then broader tests as needed.
- Call out missing system dependencies explicitly in results.
