# JiejieBoxFlutter

JiejieBox 五平台 Flutter 客户端（iOS / iPadOS / Android / macOS / Windows，本轮不做 Linux）。
UI 母版为 **FlClash v0.9.3（Prism）**，功能裁剪参考 **B-box `newui`**，代理内核与配置语义以 **JiejieBox `testing`** 为唯一权威。

> 本仓库当前处于 **P0（独立研究与 UI 证据）**：只包含基线锁定、验证工具与决策记录。
> `flutter create` / `lib/**` 的 UI 骨架从 **A1（FlClash 保真底座）** 开始；平台目录由 **C** 负责。

## 目录

```
baseline/          # 锁定的第三方基线：commit/tree/文件哈希（manifest.json）
docs/              # ADR 与工程决策
tools/             # 可复跑脚本：collect_baseline.py / verify_baseline.py
```

## 基线（不可改）

| 仓库 | 引用 | commit | 角色 |
| --- | --- | --- | --- |
| `chen08209/FlClash` | `v0.9.3` | `be84736605527034689c95bf27828ff27d912c5e` | UI/布局/尺寸权威 |
| `chen08209/prism_ui` | FlClash 子模块固定 | `63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185` | Prism 设计系统 |
| `giturass/B-box` | `newui` | `5685b141efdbe2b161702c6045ee6d46dc25d3e8` | 功能裁剪参考（非视觉权威） |
| `Piggy-Cat-bit-shadow/JiejieBox` | `testing` | `4dc2593fbc1bf736afd1d79a3fdec5f7371db328` | 内核/API 权威 |

本地只读 clone 位于 `C:\JJ\repos\{FlClash,prism_ui,B-box,JiejieBox}`。
**禁止**在这些 clone 里提交；所有修改只进本仓库。

## 验证

```powershell
python tools\verify_baseline.py
# OK: 4 repositories and 31 files match baseline/manifest.json
```

若 clone 被移动或重建，先 `python tools\collect_baseline.py` 重新生成 manifest（仅当确认上游 commit 未变）。

## 分支约定

- `main`：集成分支，只接受可复验的合并
- `feat/ui`：窗口 A 的 UI/页面/交互与最终 Flutter 集成
- `feat/platform-*`：窗口 C 的平台宿主与 `lib/bridge/**`（不碰 `lib/` 其他目录）
- `feat/core-api-*`：窗口 B 的内核兼容接口（只允许在 JiejieBox 隔离分支，不在本仓库）

## 所有权

| 范围 | 所有者 |
| --- | --- |
| `lib/**`（除 `lib/bridge/`）、`pubspec.yaml` 的 UI 依赖、最终集成 | A |
| `android/`、`ios/`、`macos/`、`windows/`、`lib/bridge/**` | C |
| JiejieBox Go 接口（仅隔离分支） | B |

## P0 环境结论（影响后续阶段）

1. **Flutter 用 3.47.6**（上游 CI pin，`.github/workflows/build.yaml:19`）：3.47.6 下 `pub get` 不改 `pubspec.lock`；3.50.0 会把 `test/test_api/test_core` 升 3 个版本。本机 SDK 在 `C:\JJ\tools\f3476\flutter`。
2. `flutter pub get` 在本机（未开 Developer Mode）会在 plugin symlink 处失败：`Building with plugins requires symlink support`。新工程第一阶段不要引入带平台代码的 plugin，即可绕开（已用 harness 验证 15/15 通过）。
3. `flutter test` 在 FlClash 上会触发 `plugins/rust_api/hook/build.dart` 的 native-assets 构建，本机无 Rust，失败于 `Building native assets failed`。编辑器依赖延后。
4. FlClash v0.9.3 的 `pubspec.lock` 在 Flutter 3.50 下会漂移；差异留在 `OUTPUT/A/P0/evidence/flclash_pubspec_lock.diff`。
5. `flutter analyze --no-pub` 在 FlClash v0.9.3 + Flutter 3.47.6 上 **0 error / 0 info**，仅 1 个 `core/Clash.Meta` 未初始化的 asset warning。见 `OUTPUT/A/P0/evidence/flutter3476_analyze.log`。

## 运行与验证（P4）

```powershell
$env:PUB_CACHE='C:\JJ\pub-cache3476'
cd C:\JJ\JiejieBoxFlutter
C:\JJ\tools\f3476\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib test
C:\JJ\tools\f3476\flutter\bin\flutter.bat analyze --no-pub
C:\JJ\tools\f3476\flutter\bin\flutter.bat test --no-pub
C:\JJ\tools\f3476\flutter\bin\flutter.bat test --update-goldens test\app_golden_test.dart
```

当前状态：analyze 0，62 tests，16 Goldens；真实 bridge 与平台编译待 C。
