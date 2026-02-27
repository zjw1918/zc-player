# Windows Hardware Decode + True Zero-Copy Design

## Goal

Deliver a production-safe Windows path where `d3d11va` hardware decode can feed rendering through true zero-copy (no decode-side CPU transfer in the true path), while preserving stable fallback behavior.

## Non-Goals (Initial Milestone)

- No requirement to make `dxva2` true-zero-copy in phase 1.
- No requirement to remove software/interop fallback paths.
- No requirement to optimize for lowest possible latency before correctness and stability are proven.

## Current Baseline

- Windows hardware decode policy is present (`auto`, `d3d11va`, `dxva2`, `off`).
- Runtime backend state machine exists (`software`, `interop_handle`, `true_zero_copy`).
- True-zero-copy semantics and fallback suppression already exist on the app/video interop side.
- Renderer currently has software upload paths and Apple true-zero-copy interop path.

## Target Runtime Model (Windows)

1. Decoder opens with `d3d11va`.
2. Decoded frame retains GPU ownership and carries a valid GPU token/metadata.
3. Renderer true path imports D3D11-backed texture resources into Vulkan resources.
4. Frame is sampled directly by shader without CPU plane upload.
5. On any import/sync failure, backend downgrades to `interop_handle` with explicit fallback reason.

## Architecture Decisions

- **Primary true path:** `d3d11va` only in phase 1.
- **`dxva2` behavior:** decode can remain enabled, but true-zero-copy not activated unless dedicated interop support is added.
- **Format support in phase 1:** `NV12` only for true path.
- **Safety gate:** keep `ZC_FORCE_INTEROP_HANDLE=1` as immediate escape hatch.
- **Activation policy:** `true_zero_copy` is reported active only after actual successful true submit.

## Interop Spec (Phase 1, frozen)

### Required Vulkan extensions and features

- `VK_KHR_external_memory`
- `VK_KHR_external_memory_win32`
- `VK_KHR_sampler_ycbcr_conversion` (required only if the ycbcr sampler path is selected)
- Format support required at runtime for phase 1:
  - `NV12` decode source
  - sampling path selected by this document (see next section)

If required extension/feature checks fail, true path must stay disabled and backend must remain on `interop_handle`.

### Handle strategy

- Primary import target: NT handle via `VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT`.
- Bridge export expectation: D3D11 resource must be exportable as a shared handle.
- If the decode surface cannot be exported as required handle type, phase 1 behavior is:
  - do not activate `true_zero_copy`
  - continue with `interop_handle` path
  - report fallback reason as `import_failure` only on real true submit attempts

## NV12 Import and Sampling Strategy (Phase 1)

- Phase 1 selected path: **dual-plane style matching current renderer abstraction**.
- Keep the renderer's existing two-sampler Y/UV model to minimize shader and descriptor churn.
- `windows_interop_bridge` must provide enough metadata to map decoded NV12 data into renderer Y and UV sampling inputs.
- If per-plane external import is unavailable on a target/driver combination, true path stays disabled and falls back.

Notes:

- A future phase may adopt a single multi-planar image + ycbcr sampler path if it materially improves portability or maintenance.
- Phase 1 prioritizes integration risk reduction over elegance.

## Cross-API Sync Strategy

### Phase 1 (conservative, required)

- Use conservative D3D11 completion before Vulkan sampling:
  1. Flush decode-side D3D11 context after frame readiness.
  2. Wait for completion via query/event-based completion primitive in bridge.
  3. Only then submit/import for Vulkan sampling.
- This path may add latency but is deterministic and easier to debug.

### Phase 2 (optimization, optional)

- Evaluate external semaphore/fence interop (`VK_KHR_external_semaphore_win32` + D3D11 fence path) to reduce stalls.

## FFmpeg D3D11VA Frame Contract

- `gpu_token` remains the transport key from decode/pipeline to renderer interop bridge.
- Token resolution in `windows_interop_bridge` must treat FFmpeg frame layout as version-sensitive:
  - do not hardcode undocumented array indices in top-level design logic
  - isolate extraction details inside a dedicated helper with validation
- Bridge must handle the D3D11 texture-array decode model (shared texture object + per-frame subresource/index).
- Validation failure (missing texture, invalid index, unsupported format) must fail true submit and trigger fallback semantics.

## Backend Integration Shape (`VideoInterop.zig`)

- Add explicit Windows true-path backend representation instead of overloading macOS backend behavior.
- Minimum shape for phase 1:
  - `BackendKind.windows_d3d11`
  - backend capability probe for true path eligibility
  - runtime status participation identical to existing true path semantics
- Keep mode semantics unchanged (`auto`, `force_software`, `force_zero_copy`).
- `force_zero_copy` remains fail-fast if Windows true path is not actually available.

## State Transition Rules (normative)

Given current backend kind is Windows true-capable:

- `true_zero_copy` status requires all of:
  - decoder backend is `d3d11va`
  - payload/token is valid for import
  - true path not currently suppressed
  - forced interop override is not active
- On true submit success:
  - clear suppression
  - clear `import_failure` fallback reason if it was set by prior true failures
- On true submit failure:
  - set suppression
  - set fallback reason `import_failure`
- On forced interop override:
  - status remains `interop_handle`
  - do not generate synthetic import-failure noise

## File-Level Implementation Plan

### Phase 1: Contracts and capability gating

#### `src/video/video_decoder_exports.zig`
- Ensure true-path metadata is carried without requiring software transfer side effects.
- For Windows + `d3d11va`, expose stable token/source metadata for renderer import.
- Keep existing software transfer path for non-true paths.

#### `native/src/video/video_decoder.h`
- Extend decoder-facing metadata contract for Windows interop requirements.
- Keep ABI additive and backward-compatible where possible.

#### `src/video/interop/VideoInterop.zig`
- Add Windows backend kind + capability checks for true-zero-copy eligibility.
- Keep fallback reason semantics aligned with true submit result.

### Phase 2: Windows native interop bridge

#### New files
- `native/src/renderer/windows_interop_bridge.h`
- `native/src/renderer/windows_interop_bridge.cpp`

#### Responsibilities
- Resolve decoder GPU token to D3D11 texture resources and plane metadata.
- Export/import-compatible handle acquisition for Vulkan external memory path.
- Reference management and deterministic release order.
- Validation helpers for expected format/plane assumptions (`NV12`).
- Centralize FFmpeg D3D11 frame field extraction behind one helper boundary.

### Phase 3: Renderer true path integration

#### `native/src/renderer/renderer.c`
- Add Windows branch in `renderer_submit_true_zero_copy_handle(...)`.
- Import external resources into Vulkan images/views for shader sampling.
- Integrate with existing slot lifecycle, descriptor updates, and cleanup logic.
- Keep existing upload paths unchanged for fallback.
- Add explicit extension/feature gate checks and early downgrade paths.

#### `native/src/renderer/renderer.h`
- Add any required structs/enums for Windows true-path metadata, minimizing API churn.

### Phase 4: Engine/session integration and behavior

#### `src/video/VideoPipeline.zig`
- Preserve true-submit result reporting path to interop state machine.

#### `src/video/video_pipeline_exports.zig`
- Keep GPU-only frame handling semantics when true path is active.
- Ensure token lifetime survives decode/render skew.

#### `src/app/App.zig`
- Keep true submit reporting tied to actual renderer submit result.

### Phase 5: Diagnostics and UX transparency

#### `native/src/ui/ui.cpp`
- Expand runtime diagnostics display for:
  - HW backend (`d3d11va`/`dxva2`/none)
  - interop backend status (`software`/`interop_handle`/`true_zero_copy`)
  - last fallback reason

#### `docs/WINDOWS_HW_DECODE.md`
- Add true-zero-copy verification guidance and known limitations for phase 1.

## Sync and Lifetime Rules

- Never release imported external resources before renderer slot replacement is complete.
- On reuse of a slot, wait/reset associated fences before replacing imported handles.
- If import succeeds but descriptor update fails, release imported resources in reverse order and mark submit failure.
- Decode-side token ownership and render-side imported resource ownership must be independently explicit.

## Fallback Policy

- Trigger fallback reason `import_failure` only on real true submit attempts.
- Do not emit import-failure noise when forced interop override is active.
- On repeated true submit failures, suppress true path and continue interop path until recovery criteria are met.

## Test Plan

### Unit and integration tests

- `src/video/interop/VideoInterop.zig`
  - true status requires payload-ready conditions
  - forced interop does not create false import-failure noise
- `src/video/video_pipeline_exports.zig`
  - GPU token lifetime stability across queue delay
- `src/app/App.zig`
  - true submit result propagates to runtime backend status transitions
- `src/video/video_decoder_exports.zig`
  - windows d3d11 token metadata contract remains valid without software transfer dependence

### Platform capability and downgrade tests

- Verify behavior when required Vulkan external-memory extension is unavailable:
  - expected: no crash, no true activation, deterministic interop fallback
- Verify behavior when bridge cannot export required shared handle:
  - expected: true submit fails, suppression applies, playback continues in fallback mode

### Correctness stress tests

- D3D11 texture-array index correctness:
  - expected: displayed frame corresponds to current decode output, no stale/previous-frame artifacts
- Resize during playback and swapchain recreation while true path eligible:
  - expected: stable rendering, no persistent validation errors, deterministic fallback on failure

### Runtime verification (Windows)

1. `ZC_HW_DECODE=d3d11va ZC_DEBUG_HW_DECODE=1 zig build run -- <media>`
   - Expect hardware decode + eligible true path transitions.
2. `ZC_HW_DECODE=dxva2 ZC_DEBUG_HW_DECODE=1 zig build run -- <media>`
   - Expect hardware decode; true path may remain disabled in phase 1.
3. `ZC_FORCE_INTEROP_HANDLE=1 zig build run -- <media>`
   - Expect stable interop behavior and no false import-failure diagnostics.

## Acceptance Criteria

- `zig build` and `zig build test` pass on Windows.
- `d3d11va` path can activate `true_zero_copy` when all gates are satisfied.
- No decode-side CPU transfer is required by the true path.
- No persistent Vulkan validation spam in normal playback.
- Visual output remains color-correct and stable during backend transitions.
- Fallback behavior remains deterministic and debuggable.
- Required extension/feature mismatch produces graceful non-true fallback (no crash).
- D3D11 texture-array frame selection is correct under sustained playback.

## Risks and Mitigations

- **External memory import incompatibility on specific drivers**
  - Mitigation: immediate fallback to interop path and record explicit reason.
- **Cross-API synchronization mistakes**
  - Mitigation: start with conservative fence-based ordering, then optimize.
- **Format mismatch and color errors**
  - Mitigation: phase-1 lock to `NV12` and explicit format validation before activation.
