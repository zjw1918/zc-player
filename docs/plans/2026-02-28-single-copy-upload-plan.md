# Plan: Reduce CPU-GPU Upload Copies (Mainline)

- Date: 2026-02-28
- Status: Draft
- Scope: `hw decode + Vulkan upload` mainline

## Current Copy Chain

Current software/intermediate path typically performs:

1. Decoder frame -> pipeline queue plane buffers (CPU copy)
2. Pipeline upload plane -> Vulkan staging mapped memory (CPU copy)
3. Vulkan staging buffer -> device-local image (`vkCmdCopyBufferToImage`)

This means two CPU copies before the mandatory GPU transfer copy.

## Why `mmap` Is Not the Main Lever Here

- This path is in-process CPU->GPU upload, not IPC/shared-file transport.
- `mmap`/file mapping does not remove `vkCmdCopyBufferToImage`.
- Bottleneck reduction should focus on removing intermediate CPU copies.

## Phase A (Low Risk, Immediate)

- Add contiguous-plane fast paths for copy routines.
- Keep current synchronization and ownership model unchanged.

Done in code:

- `renderer.c`: `copy_plane_rows()` does one bulk `memcpy` when row stride is contiguous.
- `video_pipeline_exports.zig`: queue copy path does one bulk copy when source and destination strides are contiguous.

## Phase B (Primary Gain)

Goal: remove queue deep-copy for software/interop-host planes.

Approach:

1. Queue stores frame references/metadata, not copied plane payload.
2. Decode thread retains frame ownership (`AVFrame` ref or equivalent) for queued item.
3. Render/upload thread copies directly from retained frame planes into Vulkan staging.
4. Release retained frame after upload slot consumption.

Expected result:

- One CPU copy removed (decoder -> queue copy disappears).
- Lower CPU bandwidth pressure during seeks and high bitrate playback.
- Lower transient private memory by eliminating duplicated queue plane payload.

## Phase C (Optional / Platform-Dependent)

- Evaluate host-visible device-local memory types where available.
- Keep fallback to standard host-visible staging path.
- Treat as optimization, not baseline requirement.

## Guardrails

- Must preserve seek stability and no-use-after-free guarantees.
- Must preserve cross-platform behavior and fallback semantics.
- No dependency on platform-specific zero-copy APIs in mainline.
