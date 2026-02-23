# Zero-Copy Phase 2 Design

## Goal

Design a cross-platform video interop abstraction that enables a macOS VideoToolbox-first zero-copy path while preserving the current YUV software upload path as robust fallback.

## Non-Goals

- Full production implementations for Linux/Windows zero-copy in this phase.
- Replacing audio clock master behavior.
- Removing existing software YUV path.

## Recommended Approach

Use a cross-platform interface with backend selection. Implement the macOS backend first, keep software backend as stable fallback, and make runtime switching explicit and safe.

## Architecture

- Add a new module namespace under `src/video/interop/`.
- Define a platform-neutral interop contract used by playback and renderer boundaries:
  - `init(...)`
  - `submitDecodedFrame(...)`
  - `acquireRenderableFrame(...)`
  - `releaseFrame(...)`
  - `capabilities(...)`
- Keep `src/video/video_pipeline_exports.zig` as control-plane orchestrator (timing, queue policy), but delegate frame transport ownership to selected backend.
- Backends:
  - `software_upload` backend: current CPU-plane upload behavior.
  - `macos_videotoolbox` backend: hardware-frame oriented path.

## Data Flow

1. FFmpeg decode yields `AVFrame` (software or hardware-backed).
2. Interop adapter inspects frame memory type, format, and backend capabilities.
3. `submitDecodedFrame` forwards to backend:
   - software: copies plane data into software-managed upload path.
   - macOS interop: prepares renderable GPU-backed handle/metadata for renderer consumption.
4. Renderer acquires frame via `acquireRenderableFrame`:
   - software frame path (existing upload APIs), or
   - interop frame handle path (avoid CPU plane copy when possible).
5. Rendered frame gets released with `releaseFrame`.

## Backend Selection

- Selection modes:
  - `auto` (default): prefer zero-copy backend when capability and runtime checks pass.
  - `force_software`: always software backend.
  - `force_zero_copy`: require zero-copy backend, otherwise fail open-media or downgrade based on policy.
- On any backend runtime error, downgrade to software backend for the current session without crashing.

## Sync and Smoothness Policy

- Keep audio as master clock.
- Preserve smoothness-first policy already in place.
- Keep render-boundary stale-frame dropping with small tolerance to avoid visible lag growth.
- Interop queue must preserve monotonic PTS ordering.

## Error Handling

- Init failure in zero-copy backend: log once, fallback to software backend.
- Per-frame submit/acquire failure: count errors; drop frame; if threshold exceeded, fallback to software backend.
- Swapchain/resource recreation failures: attempt backend resource rebuild, then fallback if needed.
- Do not block decode/render threads on interop resource waits; prefer dropping stale frames over hard stalls.

## Observability

Add env-gated counters/logs:

- backend selected (`software`, `macos_videotoolbox`)
- interop submit success/fail counts
- fallback-switch count and reason
- queued frame lag (ms)
- dropped-stale-frame count
- zero-copy vs software frame ratio

Logs remain disabled by default.

## Testing Plan

- Unit tests:
  - backend selection logic
  - fallback transition logic
  - queue PTS monotonicity guarantees
- Integration/smoke tests:
  - software backend baseline behavior unchanged
  - macOS capability detection and safe fallback behavior
- Acceptance playback checks:
  - heavy sample (HEVC 1440p60) keeps low visible lag
  - no regressions in build/tests

## Risks and Mitigations

- Platform interop complexity:
  - mitigate with strict fallback path and capability checks.
- Resource lifecycle bugs:
  - mitigate with clear ownership APIs (`acquire`/`release`) and teardown ordering.
- Hidden stalls:
  - mitigate with queue metrics and non-blocking behavior under pressure.

## Rollout Strategy

1. Introduce interop abstraction + software backend wrapper first.
2. Add macOS backend behind `auto/force` selection flags.
3. Validate with metrics on heavy sample.
4. Keep fallback default behavior safe at all times.
