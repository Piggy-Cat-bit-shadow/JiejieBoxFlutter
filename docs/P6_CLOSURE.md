# P6 收尾说明（最终架构与验证）

本仓库的最终集成分支是 `feat/p6-closure`。本文件描述运行时链路、验证命令和仍未覆盖的环境项，供后续构建/发布使用。

## 1. 运行时链路（Windows）

```
main
  -> createCoreRuntime()
       -> HostSupervisor.start()
            core_host_libbox.exe --pipe \\.\pipe\jjbox-host
                                 --data %LOCALAPPDATA%\JiejieBox\host
                                 --parent-pid <app pid>
            (ready when stdout prints "LISTEN pipe:")
       -> MethodChannel("jjbox/host")
            -> windows/plugins/jjbox_plugin.cpp
                 -> framed JSON over \\.\pipe\jjbox-host
                      -> windows/core_host (Go)
                           -> libbox.CheckConfig / FormatConfig / ParsePreview
       -> HostCoreBridge -> CoreConnection -> UI
```

- 默认只开命名管道；`--listen` 显式开启 TCP，仅用于 E2E/调试。
- 管道 ACL：`D:P(A;;GA;;;SY)(A;;GA;;;OW)`；同机其他用户不能打开。
- 父进程退出/崩溃时，宿主由 `--parent-pid` 看门狗退出；UI 侧另有 2s `service.status` 轮询兜底。
- 没有宿主/插件时，`createCoreRuntime()` 返回 `UnavailableCoreBridge`，不伪造 running。

## 2. 本机验证命令

```powershell
C:\JJ\tools\f3476\flutter\bin\dart.bat format --output=none --set-exit-if-changed lib test packages/jjbox_bridge
C:\JJ\tools\f3476\flutter\bin\flutter.bat analyze --no-pub
C:\JJ\tools\f3476\flutter\bin\flutter.bat test --no-pub
cd windows\core_host
go test -count=1 ./...
go build -o core_host.exe .
.\core_host.exe --selftest              # 17 checks (default)
tools\build_core_host_libbox.ps1 -Kernel <kernel-with-API-patch>
.\windows\core_host\core_host_libbox.exe --selftest   # 18 checks (linked)
tools\stage_windows_host.ps1 -OutDir <runner-dir>     # packages core_host.exe next to the app
```

`test/host_smoke_test.dart` 会用默认/ linked 两个宿主跑真实进程：默认断言 `core=false` + `config.check` 两态 `unsupported_platform`；linked 断言有效 ok / 无效 `core_rejected_config`。缺 exe 时 skip。

## 3. 未覆盖（环境）

- `flutter build windows`：需要 VS2022 "Desktop development with C++"（MSVC v142 + CMake）；本机 VS BuildTools 缺组件。
- C++ 插件未在本机编译；`Deliver` callback 投递仍为 TODO，UI 以状态轮询兜底。
- Android/iOS/macOS 的 libbox AAR/XCFramework 未构建（无 NDK/Xcode）；移动端诚实返回 `unsupported_platform`。
- 真机/NE/VpnService/TUN 本轮不做。

## 4. 提交与基线

- FlClash v0.9.3：`be84736605527034689c95bf27828ff27d912c5e`
- prism_ui：`63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185`
- JiejieBox API 分支：`feature/flutter-api` @ `1a0f4847c0b8b5d0d7426439dfdf5b4190082eae`
- 平台历史分支：`feat/platform-p5` @ `61d3c2ed65b13e373adbb8c1e01ecc1598c19d44`
