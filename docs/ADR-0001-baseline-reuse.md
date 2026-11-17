# ADR-0001：以 FlClash v0.9.3 源码为母版的复用方式

- 状态：Accepted（P0）
- 日期：2026-11-17
- 决策者：窗口 A（UI 施工）
- 相关：`baseline/manifest.json`、`OUTPUT/A/P0/UI_SOURCE_MAP.md`

## 背景

JiejieBox 需要一套新的五平台 Flutter 客户端，UI 必须与 FlClash v0.9.3 的 Prism 视觉/尺寸/响应式行为一致；同时必须移除 Mihomo 业务、接 JiejieBox sing-box 内核。可选路径有三条：

1. **整仓 fork FlClash**，在 fork 上删 Mihomo、换内核。
2. **把 FlClash 作为子模块**，新工程引用其包。
3. **按文件复用**：把需要的 `lib/ui`、`lib/features/form`、`lib/views`、`lib/common`（布局/常量/窗口）与 `prism_ui` 源文件复制进新工程，逐个改造数据层。

## 决策

采用 **方案 3 + prism_ui path 依赖**：

- `prism_ui` 作为 **path 依赖**引入（`pubspec.yaml` 指向 vendored 副本），不 fork、不改名，保持与 FlClash 子模块同 commit。
- FlClash 的 UI 源文件（`lib/ui/**`、`lib/features/form/**`、`lib/views/**`、`lib/common/{layout,constant,window}.dart`）**按需复制**到新工程 `lib/` 下，保留原文件头注释与来源标注（`// vendored from chen08209/FlClash@be84736 ...`）。
- 每个复制文件在 `VENDORED.md` 记录：源路径、源 commit、改动点、原因。**不允许**"看着像就重写"。
- 数据层（providers/core/models）不复制，按 JiejieBox API 重写（见 `OUTPUT/CONTRACTS/A_UI_CONTRACT.md`）。

## 理由

| 方案 | 问题 |
| --- | --- |
| 1 整仓 fork | 带入 Mihomo core（`core/Clash.Meta`）、drift 数据库、Rust 桥、`setup` Go/Rust 构建钩子；删除面积远大于保留面积，且 fork 长期偏离上游 |
| 2 子模块引用 | FlClash 是 application 而非 package：`main.dart`、`core/`、`plugins/*` 与平台目录耦合，`package:fl_clash` 无法作为依赖被干净引用 |
| 3 按文件复用 | 复用面可控（UI/布局/表单/窗口），Mihomo 业务天然不进入；代价是需要维护一份"来源清单"与逐文件改造 |

## 后果

- **正面**：尺寸权威链条完整保留（`layout.dart` → `prism_ui/metrics.dart`/`measure.dart`）；Golden 可与母版对齐；裁剪边界清晰。
- **负面**：上游更新不会自动进入，需要 `VENDORED.md` + 定期 diff；复制文件里的 `package:fl_clash/...` import 必须改写为新包名。
- **约束**：任何新页面若在 FlClash 找不到原型，必须先补 `UI_SOURCE_MAP.md` 证据，再按 Prism tokens 扩展；不得自造尺寸。

## 待 P1 决定

1. 新包名（暂定 `jiejiebox_flutter`）与 `lib/` 子目录命名（建议保留 `ui/`、`features/form/`、`views/`、`common/` 同名结构，降低 diff 成本）。
2. `prism_ui` 是 vendored 复制还是 `path: third_party/prism_ui` 子模块；两者都可，但不能改其源码（若必须改，另立 fork 并记录 commit）。
3. 编辑器：保留 `code_forge` + Rust（功能强、构建重）或改纯 Dart（轻、但需自写高亮/查找）。P0 未决，属 A1 的风险项。
