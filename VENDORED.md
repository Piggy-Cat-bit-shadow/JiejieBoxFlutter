# VENDORED — 本仓库中 FlClash/Prism 代码的来源清单

基线：`chen08209/FlClash@be84736605527034689c95bf27828ff27d912c5e`（v0.9.3）
Prism：`chen08209/prism_ui@63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`（位于 `third_party/prism_ui`，path 依赖）

原则：复制文件保留原逻辑与参数；改动必须在本表登记。**不允许**"看着像就重写"。

## 1. 逐字复制（仅改 import 前缀）

| 目标 | 来源 | 改动 |
| --- | --- | --- |
| `lib/ui/**`（15 个文件） | `lib/ui/**` | 仅 `null_status_illustration.dart` 的 `app_glyphs` import 改包名 |
| `lib/l10n/**`（9 个文件，生成物） | `lib/l10n/**` | 无 |
| `lib/views/dashboard/dashboard_layout.dart` | `lib/views/dashboard/layout.dart` | 无 |
| `lib/views/dashboard/dashboard_style.dart` | `lib/views/dashboard/style.dart` 的 `DashboardCorner` | 只取圆角常量 |
| `lib/common/layout.dart` | `lib/common/layout.dart` | 无（import 调整） |

## 2. 裁剪后复制（逻辑不变，删除 Mihomo/核心耦合）

| 目标 | 来源 | 改动 |
| --- | --- | --- |
| `lib/common/constant.dart` | `lib/common/constant.dart` | 只保留 UI 常量（断点/缩放/边距/存储 key/节流）；删除端口、geo 文件、core 超时等 |
| `lib/common/num.dart` | `lib/common/num.dart` | 只保留 `compact`/`fixed`；`traffic` 需要核心模型，A2 再补 |
| `lib/common/app_localizations.dart` | `lib/common/app_localizations.dart` | 删除 core/network 错误映射；保留 `AppUiLocalizations` 与 locale 解析 |
| `lib/common/enums.dart` | `lib/enum/enum.dart` | 只抽 `ViewMode`/`ProxiesLayout`/`ProxyCardType`/`PageLabel`/`NavigationItemMode` |

## 3. 新写（为替换 FlClash 的 Riverpod/核心依赖）

| 目标 | 参考 | 说明 |
| --- | --- | --- |
| `lib/common/system.dart` | `lib/common/system.dart` | 只保留平台布尔与 OS 判断 |
| `lib/common/context.dart` | `lib/common/context.dart` | `appLocalizations` 扩展（6 行） |
| `lib/state/app_state.dart` | 无（替换 `providers/*`） | 壳层状态：视口/主题/字号/页面/profile 夹具 |
| `lib/shell/app_scopes.dart` | `lib/manager/theme_manager.dart:91-125` | ViewScope（600 断点）+ MeasureScope + LayoutBuilder 上报 viewSize |
| `lib/shell/window_header.dart` | `lib/manager/window_manager.dart:383-423` | 自绘标题栏高度/分隔线；macOS 才显示标题；无窗口插件 |
| `lib/shell/home_shell.dart` | `lib/pages/home.dart` + `lib/manager/app_manager.dart:146-260` | 侧栏/底部栏/Dock、页面切换；单页而非 PageView |
| `lib/app.dart` | `lib/application.dart:159-199` | PrismApp 参数、locale/textScale、builder 注入 scopes |
| `lib/views/profiles/profiles_page.dart` | `lib/views/profiles/profiles.dart:147-266,500-570` | 网格公式/卡片结构一致；去掉订阅到期/更新时间 chip（无 API，见 CONTRACTS K15） |
| `lib/views/profiles/add_profile_menu.dart` | `lib/views/profiles/add.dart:130-162` | 菜单项/分组一致；动作记录 intent，导入逻辑 A2 接 |
| `lib/views/dashboard/dashboard_page.dart` | `lib/views/dashboard/dashboard.dart:88-142` | 2/4 列、三档密度、176/208、56/64、152/176、440 上限一致；卡片只有标题，无假数据 |
| `lib/views/tools/tools_page.dart` | `lib/views/tools.dart:21-99` | 分组 Card/ListItem 与 padding 一致；只放本地设置 |

## 4. 尚未移植（A2/A3，按 `OUTPUT/A/P0/VENDORING_PLAN.md` 顺序）

- `views/proxies/**`（T3，需 groups 数据面）
- `views/connection/**`、`views/logs.dart`、`views/dns_queries.dart`（T3，需 command client）
- `views/config/**`（Mihomo 语义，需裁剪重写）
- `features/form/**` + `widgets/input.dart`（导入表单，A2）
- `pages/editor.dart`（依赖 `code_forge` + Rust，延后）
- `pages/scan.dart`（需平台相机插件，C 提供）
