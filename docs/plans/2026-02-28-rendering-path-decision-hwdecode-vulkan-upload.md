# ADR: Rendering Path Decision (Windows / Cross-Platform)

- Date: 2026-02-28
- Status: Accepted
- Owner: zc-player media/rendering
- Related:
  - `docs/plans/2026-02-27-windows-hwdecode-true-zero-copy-design.md`
  - `docs/plans/2026-02-27-windows-hwdecode-true-zero-copy-design-review.md`

## Context

项目原计划在 Windows 路径推进 "true zero-copy"（解码面直接跨 API 导入渲染），但在长期验证中暴露出以下现实问题：

1. D3D11 与 Vulkan 跨 API 互操作约束较多，依赖驱动、扩展、句柄能力和同步细节，组合复杂度高。
2. FFmpeg `d3d11va` 帧结构与纹理数组语义存在版本/实现敏感点，维护和排障成本高。
3. 即使当前调通，后续 API 或驱动变化也可能引入较高回归风险，需要持续投入适配成本。
4. 当前已有可用且成熟的替代方案：FFmpeg 硬解 + Vulkan 渲染上传路径（CPU-GPU copy），可稳定运行并具备跨平台一致性。

## Decision

主线渲染策略确定为：

- 使用 **FFmpeg hardware decode**（优先利用硬解能力）。
- 使用 **Vulkan upload/render path**（允许 CPU-GPU copy）。
- **不将 GPU true zero-copy 作为当前版本目标能力**，不作为发布阻塞项。

换言之：性能优化以稳定可交付为前提，优先可维护性、可移植性与行为一致性。

## Scope and Non-Goals

### In Scope

- 统一主线实现和验证口径：`hw decode + Vulkan upload`。
- 保留现有回退与诊断机制，确保异常时可降级、可观测。
- 将性能工作聚焦在主线路径的可测优化（上传策略、队列节奏、同步开销）。

### Non-Goals

- 当前里程碑不追求跨 API "true zero-copy" 全平台打通。
- 不为单平台特有互操作能力牺牲整体跨平台一致性。

## Why This Decision

1. **稳定性优先**: 主线方案在现有工程条件下更可预测，故障面更小。
2. **跨平台优先**: 对平台专有 API 的依赖更少，路径更统一。
3. **维护成本可控**: 避免长期绑定在高脆弱度的跨 API 互操作细节上。
4. **交付效率更高**: 团队可以把时间投入到播放体验和质量指标，而非长期互操作适配。

## Consequences

### Positive

- 构建、调试、回归测试链路更简单。
- 平台间行为差异减少，问题复现和修复效率提升。
- 发布风险下降，版本节奏更可控。

### Trade-offs

- 相较理想 true zero-copy，存在额外上传/同步开销。
- 峰值性能上限可能低于特定平台深度互操作方案。

## Guardrails for Future Work

- true zero-copy 作为 **实验性分支能力** 保留，不影响主线发布。
- 如做相关探索，必须满足：
  1. 不破坏现有主线行为与回退策略；
  2. 功能可通过开关启停；
  3. 失败时可无损回退到主线路径。

## Re-Evaluation Triggers

仅在以下条件同时具备时重评 true zero-copy 进入主线的可行性：

1. 目标平台的驱动/运行时能力稳定，且跨版本兼容性可验证；
2. 互操作实现有明确、可测试、可维护的契约边界；
3. 在典型媒体场景下，性能收益对比主线方案具有明确工程价值；
4. 引入后不会显著提高故障率和维护成本。

## Operational KPIs (Mainline)

后续主线关注指标：

- 播放稳定性（崩溃率、卡死率）
- 首帧时间（TTFF）
- 丢帧率与渲染抖动
- 平台一致性（Windows/macOS/Linux）
- 维护与回归成本（问题定位时间、修复复杂度）

## Rollback Strategy

若主线路径在某平台出现异常，按既有策略执行降级与可观测告警；
不引入对平台专有互操作的硬依赖，确保发布版本始终具备稳定渲染回路。
