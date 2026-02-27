# Design Review: Windows Hardware Decode + True Zero-Copy

> Review of [2026-02-27-windows-hwdecode-true-zero-copy-design.md](./2026-02-27-windows-hwdecode-true-zero-copy-design.md)

## Overall Assessment

**设计整体合理**，分阶段推进策略和安全回退机制都很扎实。以下分优势和需关注点两部分展开。

---

## ✅ 设计亮点

### 1. 分阶段策略正确
Phase 1 限定在 `d3d11va` + `NV12` 是明智的 —— 将变量减到最少，与 Apple 路径的 NV12 已有基础对齐。

### 2. 现有基础设施充分可用
代码库已经具备:
- D3D11VA/DXVA2 HW 策略系统 (`src/video/video_decoder_exports.zig`)
- GPU token 通过 `AVFrame` 指针传递 + 引用计数管理 (`src/video/video_pipeline_exports.zig`)
- 运行时 interop 状态机 (`src/video/interop/VideoInterop.zig`)
- True submit 结果 → 状态降级反馈回路 (`src/app/App.zig`)

### 3. 安全回退设计
`ZC_FORCE_INTEROP_HANDLE=1` 逃生舱门 + `import_failure` 噪声抑制策略在现有测试中已验证。

### 4. 生命周期规则明确
"永不在 slot 替换完成前释放导入资源" 规则与 Apple 路径中 `destroy_video_slot_resources → release_mtl_texture` 的顺序一致。

---

## ⚠️ 需要关注/补充的问题

### 1. D3D11 Texture → Vulkan 的具体导入机制未指定

设计文档只说 "Import external resources into Vulkan images/views"，但没有指出使用哪个 Vulkan 扩展。

D3D11 ↔ Vulkan 跨 API 互操作有两条路径:

| 方式 | Vulkan Extension | Handle Type |
|---|---|---|
| `HANDLE` (NT handle) | `VK_KHR_external_memory_win32` | `VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT` |
| `KeyedMutex` 共享 | `VK_KHR_external_memory_win32` | `VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT` |

**建议**: 在 Phase 2 设计中明确:
- 使用 `VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT` + NT handle
- 需要 `IDXGIResource1::CreateSharedHandle()` 导出 D3D11 texture
- 需确认 FFmpeg 的 `d3d11va` 解码 surface 是否支持 `D3D11_RESOURCE_MISC_SHARED_NTHANDLE`
- 如果 FFmpeg 分配的 D3D11 surface **不**支持共享 handle，需要在 `windows_interop_bridge` 中做一次 GPU-GPU copy（这会削弱 "true zero-copy" 的含义）

### 2. NV12 纹理在 Vulkan 中的采样策略未指定

D3D11 的 NV12 纹理是一个单一的 `DXGI_FORMAT_NV12` 资源。但 Vulkan 端当前使用的是分离的 Y (`R8_UNORM`) + UV (`R8G8_UNORM`) 两个独立 image。

当通过 external memory 导入一个 NV12 texture 时，需要决定:
- **方案 A**: 使用 `VK_FORMAT_G8_B8R8_2PLANE_420_UNORM` 的 Ycbcr sampler —— 更干净但需要 sampler 管线变更
- **方案 B**: 将 D3D11 NV12 surface 的 subresource 0 (Y) 和 subresource 1 (UV) 分别导入为两个 Vulkan image —— 更贴近 Apple 路径的现有分离 Y/UV 设计

Apple 路径使用的是 **方案 B**（`apple_interop_create_mtl_texture_from_avframe(token, plane=0/1, ...)`），建议 Windows 路径也采用方案 B 以最小化 shader 和 descriptor 变更。但注意 D3D11 NV12 的 subresource 导出方式与 Metal 的 per-plane IOSurface 不同，需要验证是否可以分别导入 subresource。

### 3. 跨 API 同步方案缺失

设计提到 "conservative fence-based ordering"，但未指定使用什么同步原语。

D3D11 decode 完成 → Vulkan 采样需要同步。可选方式:
- `VK_KHR_external_semaphore_win32` + `ID3D11Fence`（推荐，但需 D3D11.4+ 和 `D3D11_FENCE_FLAG_SHARED`）
- 更保守: 在 bridge 中调用 `ID3D11DeviceContext::Flush()` + `ID3D11Query` 完成等待后再提交 Vulkan

**建议**: Phase 1 先用保守的 `Flush + query wait` 方式，后续再优化到外部信号量。

### 4. `VideoInterop.zig` 只有 macOS 后端

当前 `BackendKind` 只有 `software_upload` 和 `macos_videotoolbox`，`resolveBackendKind` 只检查 `mac_backend` 的能力:

```zig
// 当前代码
fn resolveBackendKind(self: *const VideoInterop) InitError!BackendKind {
    const mac_caps = self.mac_backend.capabilities();
    return switch (self.mode) {
        .force_software => .software_upload,
        .force_zero_copy => if (mac_caps.true_zero_copy) .macos_videotoolbox else error.UnsupportedZeroCopy,
        .auto => if (mac_caps.interop_handle) .macos_videotoolbox else .software_upload,
    };
}
```

**需要**: 添加 `windows_d3d11` 后端类型 + 对应的能力检查。设计文档中 Phase 1 对 `VideoInterop.zig` 只提到 "Add Windows capability checks"，建议明确:
- 新增 `BackendKind.windows_d3d11`
- 新增 `WindowsD3D11Backend.zig`（类似 `MacVideoToolboxBackend.zig`）
- 或者直接在条件编译级别处理（更简单但扩展性差）

### 5. GPU Token 的语义差异

Apple 路径: `gpu_token` 是 `AVFrame*` → 通过 `apple_interop_bridge` 提取 Metal texture 的 per-plane IOSurface handle。

Windows 路径: `gpu_token` 也是 `AVFrame*`，但需要:
1. 从 `AVFrame.data[3]` 取 `ID3D11Texture2D*`
2. 从 `AVFrame.data[4]` 或 `av_frame_get_side_data` 取 array index（D3D11VA 使用 texture array）
3. 通过 `IDXGIResource1` 获取 shared handle

这部分复杂度隐藏在 `windows_interop_bridge.cpp` 中，设计文档的描述（"Resolve decoder GPU token to D3D11 texture resources"）是正确的方向，但要注意 FFmpeg D3D11VA 的 **texture array** 模式 —— 所有帧可能共享同一个 `ID3D11Texture2D`，每帧通过不同 array index 区分。

### 6. 测试计划可以更具体

当前测试计划缺少:
- **Vulkan extension 可用性检测测试** (当系统不支持 `VK_KHR_external_memory_win32` 时的优雅降级)
- **Texture array index 正确性验证** (显示正确帧而非前一帧)
- **热切换 resize 测试** (播放中改变分辨率)

---

## 📋 总结建议

| 维度 | 评价 | 说明 |
|---|---|---|
| 总体架构 | ✅ 合理 | 分阶段、安全降级、与现有 Apple 路径对称 |
| 分阶段策略 | ✅ 合理 | d3d11va + NV12 限定合理 |
| 生命周期管理 | ✅ 合理 | 与现有 slot 系统兼容 |
| 跨 API 导入细节 | ⚠️ 需补充 | 具体 Vulkan Extension、handle type、NV12 plane 导入策略 |
| 同步方案 | ⚠️ 需补充 | 具体 D3D11→Vulkan 的同步原语选择 |
| Interop 后端架构 | ⚠️ 需补充 | `VideoInterop.zig` 的 Windows 后端集成方式 |
| FFmpeg D3D11VA 细节 | ⚠️ 需补充 | Texture array、shared handle 可用性 |
| 测试计划 | ⚠️ 可加强 | 缺少 extension 降级、texture array 正确性等场景 |

**核心风险**: FFmpeg `d3d11va` 分配的 D3D11 texture 是否支持 `SHARED`/`SHARED_NTHANDLE` flag。如果不支持，true zero-copy 将退化为 GPU-GPU copy，需要在设计中预判这一情况并决定是否仍然称其为 "true zero-copy"。

---

## Resolution Status (2026-02-27)

Design updates applied in `2026-02-27-windows-hwdecode-true-zero-copy-design.md`:

1. ✅ 补充了 Vulkan 扩展与 handle 策略（phase-1 约束）
2. ✅ 补充了 NV12 采样策略选择与 fallback 规则
3. ✅ 补充了 D3D11→Vulkan 同步策略（Phase 1 保守同步，Phase 2 优化）
4. ✅ 明确了 `VideoInterop.zig` 的 Windows 后端集成方向
5. ✅ 强化了 FFmpeg D3D11VA texture-array 与 token 语义约束
6. ✅ 扩展了测试矩阵（extension 缺失降级、array index、resize）

Remaining implementation-time validation items:

- 确认目标驱动/运行时组合下共享 handle 可用性边界。
- 确认最终采用的 bridge 提取实现与当前 FFmpeg 版本字段语义一致。
