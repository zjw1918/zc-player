# zc-player Architecture

## Overview

`zc-player` is a Zig-first desktop player with a native Vulkan/SDL3/ImGui frontend.

- Zig owns app orchestration, playback engine state, and media session control.
- Native C/C++ owns windowing, Vulkan device/swapchain/rendering, and ImGui integration.
- Media backend is single-path: Zig-exported implementations behind C ABI headers.

## Runtime Boundaries

- `src/app/App.zig`: app loop and UI action dispatch.
- `src/engine/PlaybackEngine.zig`: command queue, engine thread, snapshots.
- `src/media/PlaybackSession.zig`: player/audio/video coordination.
- `src/ffi/cplayer.zig`: Zig exports loaded into C ABI surface.
- `native/src/app/*`: SDL + Vulkan instance/device/swapchain/frame orchestration.
- `native/src/renderer/*`: video texture upload and draw pipeline.
- `native/src/ui/*`: ImGui frame lifecycle and input/actions.

## Ownership and Lifetime

- Global SDL lifecycle is owned by `native/src/app/app.c` only.
  - `app_init()` performs `SDL_Init(...)`.
  - `app_destroy()` performs `SDL_Quit()`.
- `PlaybackEngine` no longer initializes or shuts down SDL.
- `App.run()` order:
  1. `app_init`
  2. `renderer_init`
  3. `ui_init`
  4. `engine.start`
  5. main loop
  6. reverse-order teardown via `defer`

## Threads and Concurrency

- Main thread:
  - SDL event polling
  - UI frame build
  - Vulkan present path
- Engine thread (`PlaybackEngine.threadMain`):
  - command dequeue/dispatch
  - session tick and snapshot refresh
- Native media worker threads:
  - demux thread
  - video decode thread
  - audio decode thread

Synchronization:

- Zig engine queue: mutex + condition variable.
- Zig session/snapshot: dedicated mutexes.
- Native demux/audio/video pipelines: internal SDL mutex/condition primitives.

## Swapchain Recreate Flow

When window resize or out-of-date surface is detected:

1. `app_present()` triggers `recreate_swapchain()`.
2. Swapchain resources are destroyed and rebuilt, including render pass.
3. `app` invokes registered `swapchain_recreate_callback`.
4. Callback updates:
   - renderer graphics pipeline (`renderer_recreate_for_swapchain`)
   - ImGui main pipeline (`ui_on_swapchain_recreated`)

This keeps renderer and UI state aligned with the new render pass/swapchain image count.

## Build Modes

- Single backend mode only.
- No `media_impl` switching.
- `zig build` and `zig build test` compile/link against the same active native/UI stack.
