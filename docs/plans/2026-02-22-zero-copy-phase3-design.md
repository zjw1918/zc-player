# Zero-Copy Phase 3 Design

## Goal

Deliver a real GPU import path on macOS for VideoToolbox-backed NV12 frames so active true-zero-copy playback avoids the host-plane upload path.

## Definition of Done

- True-zero-copy runtime status can become active during playback on supported runtime.
- Active true-zero-copy frames do not traverse `renderer_upload_video*` upload APIs.
- NV12 true-zero-copy rendering is visually correct (placement, dimensions, aspect, color).
- Fallback to interop-handle/software remains safe and automatic.

## Scope

In scope:
- macOS backend internals for true GPU import path.
- Renderer path for GPU-handle submission and render binding.
- Runtime status/counter updates for true-zero-copy activation and fallback reasons.

Out of scope:
- Non-macOS true-zero-copy backends.
- Non-NV12 true-zero-copy formats in this phase.
- Audio clock policy changes.

## Architecture

- Keep `VideoInterop` as orchestration boundary.
- Replace host-plane payload for true path with a GPU-frame metadata payload (`RendererInteropGpuFrame`) that carries retained frame reference(s), dimensions, format, and safety tags.
- Add renderer API for GPU-handle submission (separate from software upload APIs).
- Keep existing host-bridge interop path and software path as fallback layers.

## Data Flow (True-Zero-Copy Active)

1. Decoder yields VT hardware-backed NV12 frame.
2. `MacVideoToolboxBackend.submitDecodedFrame` retains the frame reference and publishes GPU-handle metadata.
3. App submits GPU handle via renderer interop API.
4. Renderer imports/binds GPU resources for the frame and renders directly from those resources.
5. Renderer/backend release frame refs after the safe render lifecycle point.

## Format and Activation Rules

- True-zero-copy path supports NV12 only for Phase 3.
- Runtime status `.true_zero_copy` requires:
  - capability probe enabled,
  - sustained hardware-frame streak,
  - successful GPU import submissions.
- Any unsupported format or import failure triggers fallback and records reason.

## Lifetime and Safety

- Interop-handle ownership must retain frame refs while in-flight.
- Renderer slots must not outlive frame refs.
- Swapchain recreation must rebuild imported resources safely.
- On any lifecycle mismatch, drop frame and fallback (do not block decode/render threads).

## Error Handling and Fallback

- Submit-time validation failures (format/ref/size) -> drop frame + counter increment.
- Renderer import failure -> immediate fallback to host-bridge/software path.
- Force-zero-copy mode remains fail-fast at init when true capability is unavailable.

## Observability

Track and expose:
- true-zero-copy submit success/failure count
- fallback-switch count and reasons
- backend status transitions
- sustained hardware-frame streak metrics

Logs remain env-gated; UI status remains visible for operator feedback.

## Validation Plan

- Build/tests must pass (`zig build`, `zig build test`).
- Runtime checks:
  - `ZC_VIDEO_BACKEND_MODE=zero_copy ZC_EXPERIMENTAL_TRUE_ZERO_COPY=1`
  - confirm backend status transitions to `.true_zero_copy` on supported runtime.
- Visual validation on heavy sample media:
  - no wrong placement, width/height, aspect, or color regressions.
- Verify fallback behavior by forcing import failure path and confirming graceful downgrade.

## Risks

- Platform-specific interop complexity and lifetime bugs.
- Hidden synchronization issues between decode/render lifetimes.
- False-positive status reporting if activation criteria are too loose.

## Mitigations

- NV12-only first slice.
- Explicit ownership rules and slot lifecycle assertions.
- Conservative activation criteria (capability + sustained hw streak + import success).
- Preserve stable fallback path at every stage.
