# Windows Hardware Decode Guide

This project supports FFmpeg hardware decode on Windows with runtime policy control.

## Environment Variables

- `ZC_HW_DECODE`
  - `auto` (default): try `d3d11va`, then `dxva2`, then software fallback.
  - `d3d11va`: force D3D11VA only.
  - `dxva2`: force DXVA2 only.
  - `off`: disable hardware decode and use software decode.

- `ZC_DEBUG_HW_DECODE`
  - `1`: print hardware decode selection details at decoder init.
  - unset/`0`: no extra decoder selection log.

## Typical Usage

Auto policy (recommended):

```powershell
$env:ZC_DEBUG_HW_DECODE="1"
zig build run -- "C:\Users\Aurora\Videos\2024-11-30 20-14-41.mkv"
```

Force D3D11VA:

```powershell
$env:ZC_HW_DECODE="d3d11va"
$env:ZC_DEBUG_HW_DECODE="1"
zig build run -- "C:\Users\Aurora\Videos\2024-11-30 20-14-41.mkv"
```

Force software decode:

```powershell
$env:ZC_HW_DECODE="off"
$env:ZC_DEBUG_HW_DECODE="1"
zig build run -- "C:\Users\Aurora\Videos\2024-11-30 20-14-41.mkv"
```

## How to Confirm Hardware Decode Is Active

Check startup log when `ZC_DEBUG_HW_DECODE=1`:

```text
video_decoder_init: hw_enabled=1 policy=d3d11va backend=d3d11va hw_pix_fmt=... codec_id=...
```

Interpretation:

- `hw_enabled=1` means decoder opened in hardware mode.
- `backend=d3d11va` or `backend=dxva2` shows the selected FFmpeg hardware backend.
- `hw_enabled=0` with `backend=none` means software decode path.

Also verify in Windows Task Manager:

- `Performance` tab shows `Video Decode` activity on GPU while playing.

## Troubleshooting

- If `auto` does not use hardware, try forcing `d3d11va` first.
- If `d3d11va` fails on a specific machine, try `dxva2`.
- If both fail, use `off` and check driver/codec support.
- Keep FFmpeg runtime DLLs consistent with the linked package in `third_party/ffmpeg`.
