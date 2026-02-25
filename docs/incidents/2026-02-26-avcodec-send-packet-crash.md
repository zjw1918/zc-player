# 2026-02-26: `avcodec_send_packet` crash on Windows

## Symptom

- Running `zig build run -- "C:\\Users\\Aurora\\Videos\\2024-11-30 20-14-41.mkv"` crashed with a segmentation fault.
- Crash site consistently pointed to `avcodec_send_packet` from `src/video/video_decoder_exports.zig`.

## Root Cause

- In `disableHardwareDecode`, `AVCodecContext.get_format` was set to `null`.
- On non-VideoToolbox paths (Windows software decode), FFmpeg later needs a valid `get_format` callback during decode setup.
- The `null` callback caused an internal null-call path and crashed at first packet submission.

## Fix

1. Set fallback callback to FFmpeg default:
   - `codec_ctx.*.get_format = c.avcodec_default_get_format`
   - File: `src/video/video_decoder_exports.zig`
2. Harden demux packet pop error handling:
   - In `demuxerPopPacket`, check `queuePop(...)` return value and fail early on error.
   - File: `src/media/demuxer_exports.zig`
3. Stabilize runtime FFmpeg dependency resolution on Windows:
   - Use pinned n8.0 shared package path in `build.zig`.
   - Install required FFmpeg DLLs into `zig-out/bin` during build install.

## Verification

- Runtime command no longer crashes on the same media file:
  - `zig build run -- "C:\\Users\\Aurora\\Videos\\2024-11-30 20-14-41.mkv"`
- App reaches normal startup path (`Vulkan window created successfully!`).

## Follow-up

- Keep `get_format` non-null whenever hardware decode is disabled.
- If hardware policy changes, keep a regression test scenario that opens a software-decoded H.264 stream and submits at least one packet.
