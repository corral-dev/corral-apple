# Xcode 26.3 安装 iOS 27 真机包

## 现象

2026-08-29，在名为「the paired iPhone」的已配对真机上运行正式构建脚本时，手机能被发现，但构建在真机目标准备阶段失败：

```text
Timed out waiting for all destinations matching the provided destination specifier to become available
The developer disk image could not be mounted on this device.
```

## 根因

本机 Xcode 为 26.3（Build 17C519），内置 SDK 为 iOS 26.2；手机系统为 iOS 27.0（OS Build 24A5424a）。因此 Xcode 26.3 不能把这台 iOS 27 真机作为直接构建目标。手机本身并非未配对或锁定：设备状态为 connected / paired，已解锁，开发模式已开启，设备报告的开发支持服务可用。

Apple 的 Xcode 26.3 发布说明标明其 SDK 为 iOS 26.2；Apple 的系统要求页将 iOS 27 列在 Xcode 27 beta 的设备支持范围内。需要完整调试 iOS 27 时，应升级到支持该系统的 Xcode；仅为安装已签名应用时，可使用下述兼容路径。

## 可复用处理

1. 用 `xcrun devicectl list devices` 找到设备的 CoreDevice 标识，并用 `xcrun devicectl device info details --device <设备标识>` 核对 connected、paired、unlocked 和 Developer Mode。
2. 用 `xcodebuild` 的 `-destination 'generic/platform=iOS'` 构建 Release 真机包。该构建仍使用项目当前版本、签名和 arm64 真机目标，但不要求 Xcode 先把 iOS 27 手机注册为直接构建目的地。
3. 用 `xcrun devicectl device install app --device <设备标识> <Corral.app 路径>` 覆盖安装。
4. 用 `xcrun devicectl device process launch --device <设备标识> --terminate-existing com.x0c.corral` 启动。
5. 用 `xcrun devicectl device info apps --device <设备标识>` 核对 `com.x0c.corral` 的市场版本与构建号，再用 `xcrun devicectl device info processes --device <设备标识>` 确认进程实际运行；需要验证首屏可见性时，用 `xcrun devicectl device capture screenshot` 抓取真机画面。

## 禁止误判

- `xctrace` 能列出手机，或 `devicectl` 能列出 paired，并不等于当前 Xcode 能直接以该手机作为构建目的地。
- 直接目标构建失败不代表应用代码或签名失败；先区分开发支持文件不匹配、签名失败和安装失败。
- 通用真机包安装成功后仍必须单独启动、读回手机上的版本号，并确认进程运行；只看到 `BUILD SUCCEEDED` 不算真机验收完成。
- **改完手机端源码不等于 the paired iPhone 已是新版。** 用户可见改动（含对话过滤、界面）完成后必须立刻走本路径覆盖安装；禁止只提交、只跑单测、或只装模拟器。真机上回读到的市场版本与构建号才算装上。
- **`BUILD SUCCEEDED` 之后仍可能装不上。** 通用真机包编过只说明签名包已在本机；覆盖安装还要求无线开发通道当时是通的。手机休眠、离开同一 Wi-Fi、或只插着但未解锁时，会看到 `devicectl list devices` 里 the paired iPhone 变成 `unavailable`，安装报 `No route to host`（`NWError` 65）或 `CoreDeviceError` 4016（要不到电源断言 / 受信任连接）。这不是 SDK 对不上，也不是包坏了。
- **装上了但启动报 Locked，脚本仍会以失败退出。** `ios_sim.sh run` 是「覆盖安装 + 拉起」一条龙；安装成功后若手机仍锁屏，`process launch` 会报 `FBSOpenApplicationErrorDomain error 7` / `Unable to launch com.x0c.corral because the device was not, or could not be, unlocked`，整条命令因此退出码 1。这不是包坏了、也不是没装上。先用 `devicectl device info apps` 回读 `com.x0c.corral` 的市场版本与构建号——对上刚编的那一版就算覆盖完成。禁止把这条失败修成重编或改回 `platform=iOS,id=...`。点亮并解锁后再单独 `process launch`；禁止驱动本机指针去点手机。
- **装上后启动报 `Security` / `invalid code signature, inadequate entitlements or its profile has not been explicitly trusted`（2026-10-01，iOS 27.2 beta，1.0.75）。** 手机已解锁、开发者模式开、签名与描述文件（含本机 UDID、未过期）均核对无误，`ios_sim.sh run` 后连续两次 `process launch` 都被拒；随后跑 `ios-deliver run <Corral.app>` 重装即 `launch: confirmed`，进程在跑、版本回读 1.0.75 / 85。根因未确认（推测是覆盖安装后系统信任状态尚未就绪），已验证的处理：先 `info apps` 回读版本，再用 `ios-deliver` 重投，不要改签名或重编。
- **不要被假地址骗。** `iPhone-Max.coredevice.local` 若解析到 `198.18.x`，那是本机代理的假 IP，不是手机。局域网发现应以 `devicectl` 的 `available (paired)`、以及手机是否出现在当前网络的同伴设备里为准。本机代理规范要求 `.local` 不进假 IP；即使代理开着，也不要为了装 App 去关整网代理。
- **通道掉了不要重编。** 包还在时，点亮并解锁 the paired iPhone（同一 Wi-Fi 或插上数据线）后，直接再跑安装与启动即可；禁止把「设备不可达」修成改回 `platform=iOS,id=...` 直连构建。

## 验证锚点

- 通用 `generic/platform=iOS` Release 包 + `devicectl install/launch/info apps` 是现行真机路径；曾在 the paired iPhone（iOS 27）上多次覆盖成功。
- 安装成功但 `process launch` 因锁屏失败时，以 `info apps` 回读版本为准，禁止当安装失败重编。
- 通道 `unavailable` / `No route to host` 时只恢复通道后重装，禁止改回直连目标。

## Portable macOS regression scope

- Run `swift test --jobs 2` for product logic that uses macOS-available frameworks:
  crypto, connection arbitration, protocol decoding, per-host stores, conversation
  merging/lifecycle, notification action decisions, and composer recovery. The
  explicit `Package.swift` source/test lists define this scope; their excludes
  must remain disjoint from sources. See the official
  [package target documentation](https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html).
- UIKit/SwiftUI layout and the real `AppModel` remain Xcode-only. Generate the
  project from `project.yml`, compile the full app and unit-test target, then use
  the paired physical device for hosted tests and interaction acceptance. The SPM
  manifest does not affect Xcode target membership.
- Review failure (2026-09-30): cache/timeline tests could not find
  `ConversationStore` because its product source was missing from the portable
  list. Add the real dependency; do not drop its valid tests. Data safety tests
  were split from `AppModelIdentityTests` to retain portable lifecycle coverage
  while keeping actual app-model assertions in the hosted target.
- `swift package describe` checks manifest membership only. Compilation, passing
  regressions, signed app builds, installation, and phone interaction require
  separate evidence.

<!-- 该文档整理/压缩于 2026-10-20 -->
