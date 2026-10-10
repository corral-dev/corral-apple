# 推送环境必须按签名派生（2026-09-30）

## 症状 / 触发词

完成通知在手机上收不到、干完了没推送、APNs token 注册后仍无推送、
Release 包推送全丢、换了 Release 包推送行为没变。

## 结论（先看这段）

- `push.register` 上报的 `env` 必须来自**实际签名**（`embedded.mobileprovision`
  中 `Entitlements.aps-environment`），**禁止**用 `#if DEBUG` 按构建配置推导。
- 实测：Release 构建配置 + iOS Team Provisioning Profile（development）签出的包，
  其 `aps-environment` 是 `development`；旧的 `#else "production"` 会把 token
  注册到错误的环境，APNs 按错环境投递 → 静默丢失。
- 取不到或读不懂签名环境时**不上报**（safe failure），绝不猜一个 env 发出去；
  更不许为了修上线而把所有包硬写成 `production`。
- 上报时机保持不变：连接成功、拿到 device token、回到前台时重报，修正后的 env
  随下一次上报到达开发机。

## 为什么不能用构建配置

Apple `aps-environment` 文档：Xcode 按当前 provisioning profile 设定该值。
构建配置（Debug/Release）只决定 `$(APS_ENVIRONMENT)` 的**期望值**，实际生效的是
profile。开发中的包（包括 Release 配置）经常用 development profile 签名，
两者必然漂移。以后切到 Ad Hoc / App Store profile 时，签名变 `production`，
手机侧无需改代码，行为自动跟随。

## 为什么不用 SecTask 读 entitlement

`SecTaskCopyValueForEntitlement` 只在 macOS SDK 提供，iPhoneOS SDK 的 Security
framework 没有该符号。iOS 上可上架的读法是解析自带包内的
`embedded.mobileprovision`（CMS 外壳里取 plist → `Entitlements.aps-environment`）。
读自己包内文件，不触私有 API。

## 实现位置

- `Shared/Core/Push/PushEnvironment.swift`：纯解析 + 映射（`development`→`sandbox`，
  `production`→`production`，其它/缺失→`nil`），Foundation only，可移植单测。
- `iOS/Push/PushRegistrar.swift`：仅环境取值与注册守卫；权限、分类、点击/回复、
  NSE 解密一律不动。
- 回归：`Tests/PushEnvironmentTests.swift`（Xcode + portable `swift test`）。

## 验证

- `swift test --filter PushEnvironment` 绿。
- Release 通用包编过后，`codesign -d --entitlements` 读出的 `aps-environment`
  与手机上报 env 的映射一致（development↔sandbox，production↔production）。

## 已核验的交付边界（2026-09-30）

- 当前支持的交付路径（`devicectl` 直装 `.app`、AppShelf 由已签名 `.app` 打 IPA）
  都会保留包内 `embedded.mobileprovision`，运行时一定能读到签名环境。
- App Store / TestFlight 分发**不在当前支持范围**：那两条路会剥掉包内 profile，
  届时 `current()` 将返回 `nil` 从而跳过上报。按 Apple 规则，经商店分发的包
  永远走 production APNs，因此将来若加商店分发，fallback 必须是 `production`——
  但那属于新交付形态的改动，不在本修里用构建配置预埋猜测。
- 跳过上报时保持本文件既有静默风格（与 `_ = try?` 一致），不另起日志体系；
  漏报的排查入口是本篇与 `push.register` 的 `env` 字段。
