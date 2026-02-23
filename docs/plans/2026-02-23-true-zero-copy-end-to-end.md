# True Zero-Copy End-to-End Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship only when decode-to-render path is truly zero-copy end-to-end (no `av_hwframe_transfer_data` in true path), with stable color, sync, and fallback behavior.

**Architecture:** Keep current safe interop path as baseline, then add a strict true path that preserves hardware frame ownership from decoder through queue/snapshot/interop into renderer import. True path is only reported active after real render submit success and is immediately suppressible on failure. Final release criteria require visual correctness, no validation spam, and deterministic fallback.

**Tech Stack:** Zig 0.15.2, native C/C++ (SDL3 + Vulkan + FFmpeg + VideoToolbox), Metal/CVPixelBuffer bridge (`.mm`), Zig build/test.

---

### Task 1: Baseline and guardrails

**Files:**
- Modify: `src/video/interop/VideoInterop.zig`
- Modify: `src/app/App.zig`
- Modify: `native/src/ui/ui.cpp`
- Test: `src/video/interop/VideoInterop.zig`
- Test: `src/app/App.zig`

**Step 1: Write failing tests for release semantics**
- Add tests asserting:
  - true status only when payload ready + not suppressed
  - forced interop mode does not generate import-failure fallback noise

**Step 2: Run tests to verify fail**
- Run: `zig build test -- --test-filter "true-zero-copy"`
- Expected: failures in new assertions.

**Step 3: Implement minimal status/fallback cleanup**
- Ensure fallback reason changes only on actual true submit attempts.
- Keep `ZC_FORCE_INTEROP_HANDLE=1` as explicit escape hatch.

**Step 4: Re-run targeted tests**
- Run: `zig build test -- --test-filter "true-zero-copy"`
- Expected: pass.

**Step 5: Commit**
```bash
git add src/video/interop/VideoInterop.zig src/app/App.zig native/src/ui/ui.cpp
git commit -m "fix: align true-zero-copy status and fallback semantics"
```

### Task 2: Decoder true-path without hw->sw transfer

**Files:**
- Modify: `src/video/video_decoder_exports.zig`
- Modify: `native/src/video/video_decoder.h`
- Modify: `src/media/player_exports.zig`
- Modify: `native/src/player/player.h`
- Test: `src/video/video_decoder_exports.zig`

**Step 1: Write failing test for transfer bypass contract**
- Add test that true-path token/source metadata remains valid without requiring sw transfer copy side effects.

**Step 2: Run failing test**
- Run: `zig build test -- --test-filter "video_decoder true path"`
- Expected: fail before code change.

**Step 3: Implement minimal true-path split in decode**
- Preserve `hw_frame_ref` for true path and avoid `av_hwframe_transfer_data` for that path.
- Keep existing sw transfer path for interop/software fallback.

**Step 4: Re-run decoder tests**
- Run: `zig build test -- --test-filter "video_decoder"`
- Expected: pass.

**Step 5: Commit**
```bash
git add src/video/video_decoder_exports.zig native/src/video/video_decoder.h src/media/player_exports.zig native/src/player/player.h
git commit -m "feat: bypass hw-to-sw transfer on true-zero-copy decode path"
```

### Task 3: Queue/frame lifetime correctness for hardware tokens

**Files:**
- Modify: `src/video/video_pipeline_exports.zig`
- Modify: `native/src/video/video_pipeline.h`
- Modify: `src/video/VideoPipeline.zig`
- Test: `src/video/video_pipeline_exports.zig`

**Step 1: Write failing lifetime/ordering tests**
- Add tests for queued frame token stability across decode/render timing skew.

**Step 2: Run test to verify fail**
- Run: `zig build test -- --test-filter "video_pipeline"`
- Expected: new tests fail.

**Step 3: Implement minimal token lifetime fix**
- Ensure token ownership/ref retention survives queue delay and release happens in deterministic order.

**Step 4: Re-run tests**
- Run: `zig build test -- --test-filter "video_pipeline"`
- Expected: pass.

**Step 5: Commit**
```bash
git add src/video/video_pipeline_exports.zig native/src/video/video_pipeline.h src/video/VideoPipeline.zig
git commit -m "fix: enforce queued hardware token lifetime for true path"
```

### Task 4: Renderer import correctness (layout/memory/color)

**Files:**
- Modify: `native/src/renderer/renderer.c`
- Modify: `native/src/renderer/renderer.h`
- Modify: `native/src/renderer/apple_interop_bridge.mm`
- Modify: `native/src/renderer/apple_interop_bridge.h`
- Modify: `src/shaders/video.frag`

**Step 1: Add failing runtime check harness note**
- Document reproducible command and expected visual check in comments/test notes near renderer true submit path.

**Step 2: Reproduce corruption (if still present)**
- Run: `ZC_VIDEO_BACKEND_MODE=zero_copy ZC_EXPERIMENTAL_TRUE_ZERO_COPY=1 zig build run -- '/Volumes/collections/艾尔登法环/meilinna1.mp4'`

**Step 3: Implement minimal renderer import corrections**
- Keep imported images in valid external layout (`GENERAL` for descriptor use).
- Ensure memory import parameters satisfy Vulkan spec + Metal handle requirements.
- Keep slot replacement synchronized to avoid descriptor/use-after-free races.
- Remove temporary UV swap workaround once import path is verified correct.

**Step 4: Verify runtime + validation cleanliness**
- Run same command with and without `ZC_FORCE_INTEROP_HANDLE=1`.
- Expected: no validation errors; no tint; stable playback.

**Step 5: Commit**
```bash
git add native/src/renderer/renderer.c native/src/renderer/renderer.h native/src/renderer/apple_interop_bridge.mm native/src/renderer/apple_interop_bridge.h src/shaders/video.frag
git commit -m "fix: make true-zero-copy renderer import color-correct and stable"
```

### Task 5: Promote true path and finalize release gates

**Files:**
- Modify: `src/app/App.zig`
- Modify: `src/video/interop/VideoInterop.zig`
- Modify: `native/src/ui/ui.cpp`
- Modify: `docs/plans/2026-02-23-true-zero-copy-end-to-end.md`

**Step 1: Write failing test for final activation policy**
- Add tests that true status activates by default only when true submit succeeds, and cleanly downgrades on failure.

**Step 2: Run tests to verify fail**
- Run: `zig build test -- --test-filter "true-zero-copy"`

**Step 3: Implement final policy**
- Default: true path eligible and active when gates satisfied.
- Safety: `ZC_FORCE_INTEROP_HANDLE=1` forces interop path.
- UI: fallback reason remains meaningful, not noisy.

**Step 4: Full verification**
- Run:
  - `zig build`
  - `zig build test`
  - `ZC_VIDEO_BACKEND_MODE=software zig build run -- '/Volumes/collections/艾尔登法环/meilinna1.mp4'`
  - `ZC_VIDEO_BACKEND_MODE=zero_copy zig build run -- '/Volumes/collections/艾尔登法环/meilinna1.mp4'`
  - `ZC_VIDEO_BACKEND_MODE=zero_copy ZC_FORCE_INTEROP_HANDLE=1 zig build run -- '/Volumes/collections/艾尔登法环/meilinna1.mp4'`

**Step 5: Commit**
```bash
git add src/app/App.zig src/video/interop/VideoInterop.zig native/src/ui/ui.cpp docs/plans/2026-02-23-true-zero-copy-end-to-end.md
git commit -m "feat: finalize end-to-end true-zero-copy rollout with safety gate"
```

### Task 6: Final release evidence and handoff

**Files:**
- Modify: `docs/plans/2026-02-23-true-zero-copy-end-to-end.md`

**Step 1: Capture acceptance checklist results**
- Record: backend transitions, fallback behavior, visual correctness, and validation-layer cleanliness.

**Step 2: Confirm no regressions**
- Run: `zig build test`

**Step 3: Commit release evidence**
```bash
git add docs/plans/2026-02-23-true-zero-copy-end-to-end.md
git commit -m "docs: record true-zero-copy acceptance evidence"
```

---

## Acceptance Criteria (Release Gate)

- No decode-side hw->sw transfer on true path.
- `backend: true-zero-copy` only when true render submit actually succeeds.
- `ZC_FORCE_INTEROP_HANDLE=1` always keeps stable interop path without false `import-failure` noise.
- No persistent tint/corruption during interop <-> true transitions.
- No Vulkan validation spam in default and forced runs.
- `zig build` and `zig build test` pass.
