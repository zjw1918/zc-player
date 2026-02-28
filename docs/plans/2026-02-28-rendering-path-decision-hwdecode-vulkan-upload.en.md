# ADR: Rendering Path Decision (Windows / Cross-Platform)

- Date: 2026-02-28
- Status: Accepted
- Owner: zc-player media/rendering
- Related:
  - `docs/plans/2026-02-27-windows-hwdecode-true-zero-copy-design.md`
  - `docs/plans/2026-02-27-windows-hwdecode-true-zero-copy-design-review.md`

## Context

We originally planned to push a Windows true zero-copy path (decoded surfaces imported directly across APIs into rendering). After extended investigation and prototyping, the following practical issues became clear:

1. D3D11 <-> Vulkan interop has many constraints (driver/runtime combinations, extension availability, handle compatibility, sync semantics), leading to high integration complexity.
2. FFmpeg `d3d11va` frame contracts and texture-array semantics are sensitive to implementation details and version changes, which increases maintenance and debugging cost.
3. Even if the path is stabilized now, future API/driver changes may cause regressions and require continuous adaptation.
4. We already have a mature and stable alternative: FFmpeg hardware decode + Vulkan upload/render path (CPU-GPU copy), with better cross-platform consistency.

## Decision

The mainline rendering strategy is:

- Use **FFmpeg hardware decode** whenever available.
- Use **Vulkan upload/render path** (CPU-GPU copy is allowed).
- **Do not treat GPU true zero-copy as a current product requirement** and do not block releases on it.

In short: optimize for reliable delivery first; prioritize maintainability, portability, and predictable behavior.

## Scope and Non-Goals

### In Scope

- Standardize mainline implementation and validation around `hw decode + Vulkan upload`.
- Keep existing fallback and diagnostics behavior so failures remain recoverable and observable.
- Focus performance work on measurable improvements within the mainline path (upload strategy, queue pacing, synchronization overhead).

### Non-Goals

- No cross-API true zero-copy rollout as a current milestone.
- No sacrificing cross-platform consistency for platform-specific interop features.

## Why This Decision

1. **Stability first**: the selected path is more predictable under current engineering constraints.
2. **Cross-platform first**: reduced dependence on platform-specific native interop APIs.
3. **Lower maintenance cost**: avoids long-term coupling to brittle cross-API details.
4. **Better delivery velocity**: engineering effort can focus on playback quality and product metrics.

## Consequences

### Positive

- Simpler build/debug/regression workflow.
- Less platform divergence, faster issue reproduction and fixes.
- Lower release risk and more predictable release cadence.

### Trade-offs

- Additional upload/sync overhead versus an ideal true zero-copy path.
- Peak performance ceiling may be lower than deeply platform-optimized interop implementations.

## Guardrails for Future Work

- Keep true zero-copy as an **experimental branch capability** that does not block mainline release.
- Any exploration must satisfy all of the following:
  1. Must not break existing mainline behavior or fallback semantics.
  2. Must be controlled by an explicit feature switch.
  3. Must safely fall back to the mainline path on failure.

## Re-Evaluation Triggers

Reconsider promoting true zero-copy to mainline only when all conditions are met:

1. Driver/runtime capability is stable across target platforms and versions.
2. Interop behavior is bounded by clear, testable, maintainable contracts.
3. Measured gains are meaningful in representative media workloads.
4. Reliability and maintenance burden do not materially regress.

## Operational KPIs (Mainline)

Mainline optimization and validation focus on:

- Playback stability (crash/hang rate)
- Time to first frame (TTFF)
- Dropped-frame rate and render jitter
- Cross-platform consistency (Windows/macOS/Linux)
- Maintenance and regression cost (time-to-diagnose, fix complexity)

## Rollback Strategy

If mainline behavior degrades on any platform, use existing downgrade and diagnostics mechanisms;
avoid hard dependency on platform-specific interop so release builds always retain a stable rendering path.
