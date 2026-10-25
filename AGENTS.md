<!-- managed:inherited-agents:start -->
<!-- source: ~/Codes/Corral/AGENTS.md -->
# Corral

终端会话接力 CLI，支持跨 Claude Code / Codex / OpenCode / Cursor / Pi 会话恢复与接力（另有 Kimi 兼容实现 dormant：保留、不维护、无界面入口）。

通用工程规范：[Python 规范](~/Codes/_standards/python.md)

## 文档导航

Read the documents whose described content is relevant before deciding or changing behavior.

- [Agent workflow](~/Codes/Corral/cli/docs/AGENT_WORKFLOW_GUIDE.md): Readiness, resource ownership, resumable delivery and checkpoints.
- [Product task routing](~/Codes/Corral/cli/docs/PROJECT_TASK_ROUTING_GUIDE.md): Detailed cross-component preconditions and investigation routes.
- [CLI instructions](~/Codes/Corral/cli/AGENTS.md): Terminal UI, runtime integration, local development and CLI delivery.
- [Apple instructions](~/Codes/Corral/apple/AGENTS.md): Shared iPhone/Mac client, native UI, signing and device delivery.
- [Relay instructions](~/Codes/Corral/relay/AGENTS.md): Encrypted relay service, APNs and self-hosting.
- [Public presentation](~/Codes/Corral/cli/docs/PUBLIC_PRESENTATION_GUIDE.md): Approved identity, brand assets and sanitized captures.
- [Independent UI annotation](~/Codes/_standards/workspace-docs/IOS_UI_ANNOTATION_COMPONENT_DESIGN.md): Independent EditHere core and optional Corral adapter boundary.
- [Remote protocol](~/Codes/Corral/cli/docs/REMOTE_KNOWLEDGE_BASE.md): Pairing, relay/security boundaries, message delivery and multi-runtime acceptance.
- [Mobile data plane](~/Codes/Corral/cli/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md): History loading, live data isolation, question state and reconnect recovery.
- [Managed session identity](~/Codes/Corral/cli/docs/design/PI_SESSION_IDENTITY_EXTENSION_DESIGN.md): Pi/Codex ownership, claims, plugins and legacy migration.
- [Completion notifications](~/Codes/Corral/cli/docs/design/AGENT_COMPLETION_NOTIFICATIONS_DESIGN.md): Completed/interrupted evidence, notification preferences and sound presets, deduplication and delivery.
- [Historical multi-agent report](~/Codes/Corral/docs/2026-08-16-多助手会话专项汇报.md): Single-day archive, not current behavior authority.
- [UI change-request adapter](~/Codes/Corral/docs/design/IOS_UI_CHANGE_REQUEST_DESIGN.md): Corral's optional adapter for independent UI annotation.

## 组件一览

| 目录 | 技术栈 | 状态 |
|---|---|---|
| `cli/` | Python | 活跃 |
| `apple/` | SwiftUI | 活跃 |
| `relay/` | Go | 活跃（零知识中继 + APNs） Remote：`ssh://git@forgejo.caozc.top:2222/Max/corral-relay.git` |

## SessKit and Corral ownership

- Before changing session behavior, identify the owning layer and state where the fix belongs. A symptom appearing in Corral does not make its implementation Corral-owned.
- **SessKit owns native history interpretation and reusable session semantics:** runtime file/database formats, session and message extraction, real activity timestamps, native completion/error evidence, normalized schemas, transcript/activity projections and incremental history readers. Fix these in `~/Codes/SessKit`, with its parser tests and contract; never duplicate the fix in Corral scanners, remote handlers or Apple clients.
- **Corral owns product behavior:** runtime launch/resume/handoff, managed-session ownership and claims, tmux hosting, generated titles, attention/read/notification policy, product cache storage, remote transport, and client presentation, filtering, sorting and date grouping. Consume SessKit's normalized evidence; do not reinterpret raw history to bypass an upstream defect. Generic evidence belongs upstream; product decisions remain here.
- Keep the dependency direction **Corral → SessKit**. Corral's scan aliases and bridge adapt/delegate; they are not a second parser. Pass host-specific behavior through explicit extension contracts. Never move Corral UI, relay, hosting or product policy into SessKit, and never make SessKit depend on Corral.
- Runtime support is decided per product: Corral's five-runtime allowlist and dormant compatibility do not narrow SessKit's independent runtime support.
- For an upstream fix, publish a versioned SessKit artifact, update Corral's complete dependency pin, invalidate derived caches through the provider version, and verify the installed host plus affected clients. For an independent Corral fix, do not change SessKit merely because it supplies the data. Integration details: [session scanning knowledge base](~/Codes/Corral/cli/docs/SESSION_SCANNING_KNOWLEDGE_BASE.md).

## 领域地图（doc-init）

<!-- 覆盖度复核基线：2026-09-29 · 源码指纹 扫描 673 文件 / Python 190 · Swift 86 · Go 23 / 3 子模块 -->

| 领域 | 入口锚点 |
|------|---------|
| 终端界面 | cli/src/corral/ui/ · cli/src/corral/activity_board.py · cli/src/corral/cli.py · cli/src/corral/display.py · cli/src/corral/textutil.py · cli/src/corral/theme.py · cli/src/corral/store.py · cli/src/corral/i18n.py · cli/src/corral/split_layout.py · cli/src/corral/ui_prefs.py |
| 会话关注状态 | cli/src/corral/attention.py · cli/src/corral/attention_signals.py · cli/src/corral/cursor_observer.py · cli/src/corral/store.py · cli/src/corral/ui/ |
| 会话全文搜索 | cli/src/corral/search.py · cli/src/corral/ui/search_modal.py |
| 内嵌实时终端 | cli/src/corral/embed.py · cli/src/corral/ui/embed_pane.py |
| 会话扫描与对话内容 | **真源在 SessKit**（`~/Codes/SessKit` / `sesskit` 包）；`cli/src/corral/scan/` 为模块别名 · cli/src/corral/transcript.py · cli/src/corral/models.py · cli/src/corral/runtime/ · cli/docs/SESSION_SCANNING_KNOWLEDGE_BASE.md |
| 跨助手接力与启动 | cli/src/corral/runtime/ · cli/src/corral/runtime/pi.py · cli/src/corral/models.py |
| 新助手接入 | cli/src/corral/runtime/ · cli/src/corral/scan/ · cli/src/corral/runtime/pi.py · cli/src/corral/scan/pi.py |
| 托管会话身份 | cli/src/corral/pi_identity.py · cli/src/corral/pi_migration.py · cli/src/corral/codex_identity.py · cli/src/corral/pi_extension/ · cli/docs/design/PI_SESSION_IDENTITY_EXTENSION_DESIGN.md · cli/tests/test_pi_identity.py · cli/tests/test_pi_migration.py |
| 性能、派生缓存与原生加速 | cli/src/corral/cache.py · cli/src/corral/cache_cli.py · cli/src/corral/scan_index.py · cli/src/corral/native.py · cli/src/corral/schedprio.py · cli/src/corral/bootstrap.py · cli/rust/lib.rs · cli/Cargo.toml · cli/scripts/benchmark.py |
| 可观测与诊断 | cli/src/corral/observe.py · cli/src/corral/agent_api.py |
| 会话保活 | cli/src/corral/keepalive.py · cli/src/corral/liveness.py · cli/src/corral/legacy_names.py |
| 直启子命令 | cli/src/corral/cli.py · cli/src/corral/projects.py |
| 命令拦截（shim） | cli/src/corral/shim.py · cli/src/corral/bootstrap.py · cli/src/corral/runtime/registry.py |
| 标题补全 | cli/src/corral/titles.py · cli/src/corral/titlegen.py |
| Agent 只读查询 | cli/src/corral/agent_api.py |
| 手机远程接力（开发机侧） | cli/src/corral/remote/ · cli/docs/REMOTE_KNOWLEDGE_BASE.md（文首「开源中继硬规则」：公开默认关中继、无维护者域名） · cli/src/corral/bootstrap.py · cli/tests/test_remote_service.py |
| Apple 客户端（iPhone + 原生 Mac） | apple/ · apple/AGENTS.md · apple/Shared/（两端共享代码）· apple/macOS/ · apple/docs/UI_DESIGN_KNOWLEDGE_BASE.md · apple/docs/design/MACOS_CLIENT_DESIGN.md（局域网优先；自建中继才换网；开源与自编译版禁止内置共享中继，仅官方付费版可用托管中继，见远程知识库开源中继硬规则第 6 条） |
| 零知识中继与 APNs | relay/ · relay/docs/PROTOCOL_V2.md · 开源自建见 relay/README；个人多租户公网运维只在私有 agentsync（禁止写入公开门面当默认） |
| Windows / WSL 兼容（已裁定不做） | cli/docs/design/WINDOWS_COMPATIBILITY_DESIGN.md |
| 开源发布与一键安装 | cli/install.sh · cli/.github/workflows/ · cli/scripts/publish-release.sh |
| CI 流水线 | cli/.github/workflows/test.yml · cli/scripts/ci-test.py · cli/.githooks/pre-push · cli/scripts/install-git-hooks.sh |
| 客户端自动更新 | cli/src/corral/updater.py · cli/src/corral/ui/update_toast.py |
| 隐私与本地数据边界 | cli/PRIVACY.md |

## 待补充知识库（doc-init backlog）

（当前无待补充项；开源自建中继看 `relay/README.md`；维护者本机多租户公网运维只在私有 agentsync，禁止当开源默认地址。）

覆盖度扫描必须跳过手机端 Xcode 构建缓存（`apple/.derivedData*`）；不跳过会把文件数顶到上限、把 Swift 入口扫没。

<!-- project-owned: runtime-support -->
## 跨端缺陷修复（永久，2026-10-05 机主要求）

用户报告的缺陷无论出现在哪一端（iPhone、原生 Mac、终端界面 TUI），都要按同一用户场景检查其余两端；同样存在的在同一任务里一并修复、逐端验收，交付说明写明每端的检查结论（已修 / 不复现 / 该端无此功能）。

- **开发机侧**（`cli/`，含远程服务与 SessKit 扫描）的根因修一处，三端都受益，客户端无需发版，但仍要在受影响的端上验收。
- **`apple/Shared/` 公用代码**修一处覆盖 iPhone 与 Mac：两端都要真机 / 真窗验收并一起发版安装；只发一端，另一端继续跑旧代码，且公用改动可能改坏另一端。`#if os(...)` 平台分支与 `Shared/UI/Platform/` 只修到其中一端。
- **各端外壳**（`apple/iOS/`、`apple/macOS/`、TUI）代码互不共享；同类功能（分屏、侧栏、分组、焦点、搜索、状态点、提问面板等）要逐端对照行为，不能因代码不同就跳过。

## 运行时支持（Corral 产品边界，永久）

- 仅支持五个活跃运行时：Claude Code、Codex、OpenCode、Cursor、Pi；此为显式 allowlist，新增不在 allowlist 内的运行时需未来用户显式决策后才可加入。
- 已有 Kimi 兼容实现（适配器/shim/扫描/样式/资源/历史解析/测试夹具）可保留于源码与磁盘，处于 dormant：不再维护、不新增功能、不在任何用户可见入口中出现（新建会话、助手选择器/目录/筛选、接力/恢复/菜单、TUI 与手机侧列表/详情入口均隐藏）。
- 存量用户历史文件始终保留不删；展示与投影层按活跃 allowlist 过滤，不泄露入口；直接的程序化兼容调用可保留但不经 UI 暴露。

<!-- managed:inherited-agents:end -->

# corral iOS 客户端

本仓含手机端会话接力 App（扫码配对开发机、浏览/输入会话、本地解密推送）与原生 Mac 客户端（`CorralMac`，同一套远程协议，只连开发机、不在本机跑助手）；两端共享 `Shared/` 下的代码与资源。手机会话详情按 2026-10-14 机主要求恢复原生助手终端切换（见硬约束第 9 条）；Mac 客户端按 2026-10-04 机主要求已上线终端视图，每格可在聊天与助手原生界面之间切换，见 Mac 设计文档。


通用工程规范：[Swift 规范](../../_standards/swift.md)

Agent development entry: `python3 scripts/client_diag.py doctor` checks local prerequisites; `status --active`, `events --run <clientRun>` and `verify` read real client evidence without UI automation or credentials. Missing/stale reports are not healthy clients. Build and delivery keep using the documented Xcode scripts and `ios-deliver`; see the [diagnostic contract](docs/design/IOS_OPTIMIZATION_PROGRAM.md#agent-diagnostic-entry).

## Apple documentation

Read the documents whose described content is relevant before deciding or editing.

- [Task routing](docs/AGENT_TASK_ROUTING_GUIDE.md): Detailed domain preconditions, symptom routes and exceptions.
- [Session header design](docs/design/SESSION_HEADER_DESIGN.md): read before completing the adopted conversation-header redesign.
- [Haptic feedback design](docs/design/HAPTIC_FEEDBACK_DESIGN.md): Implemented user-action and outcome feedback, quiet reading/streaming rules, foreground deduplication, default behavior without settings, evidence-gated arrival/completion cues.
- [iPad and Mac client adaptation](docs/design/MULTIPLATFORM_CLIENT_DESIGN.md): Product positioning and core selling points of the native Apple client (performance, many agents, developer-first, split panes, chat/terminal switching) and its open-source state.
- [Business model and licensing plan](docs/design/BUSINESS_MODEL_AND_LICENSING_PLAN.md): Free first App Store release (2026-10-10), licensing and CLA, submission readiness, hosted-relay boundary, overseas distribution and deferred monetization.
- [Public client builds](docs/PUBLIC_BUILD_GUIDE.md): Public-source history, platform requirements, local signing, installation and verification limits.
- [Privacy](PRIVACY.md): Session authorization, client caches, Keychain, encrypted transport and relay metadata.
- [Contributing](CONTRIBUTING.md): Client checks and contributor agreement; software licensing, brand policy and third-party notices.
- [Native macOS client design](docs/design/MACOS_CLIENT_DESIGN.md): Native Mac architecture, desktop behavior, terminal, direct-download/store distribution boundaries, software updates and acceptance.
- [iPhone agent terminal](docs/design/IPHONE_AGENT_TERMINAL_DESIGN.md): Chat/terminal switching, native UIKit emulator, keyboard, foreground stream ownership and acceptance.
- [Project terminal design](docs/design/PROJECT_TERMINAL_DESIGN.md): Host-side project shells as Mac split panes (⌥F12) and an iPhone full-screen terminal, `shell.*` wire, latest-viewer sizing and acceptance.
- [Split project contract](docs/design/MACOS_SPLIT_PROJECT_CONTRACT.md): Same-project rule for agent splits, Add Pane project inheritance and mixed-group display.
- [Conversation time design](docs/design/CONVERSATION_TIME_DESIGN.md): Centered approximate message time labels, grouping rules and native-client acceptance.
- [Chat diagram design](docs/design/CHAT_DIAGRAM_RENDERING_DESIGN.md): Mermaid/PlantUML recognition, Corral appearance, offline rendering, streaming continuity, native integration and acceptance.
- [../cli/docs/REMOTE_KNOWLEDGE_BASE.md](../cli/docs/REMOTE_KNOWLEDGE_BASE.md): Pairing, encrypted remote protocol, delivery, relay boundaries and remote acceptance.
- [`docs/EDITHERE_CLOSED_LOOP_GUIDE.md`](docs/EDITHERE_CLOSED_LOOP_GUIDE.md): EditHere-to-Corral UI annotation handoff, request handling and end-to-end acceptance.
- [`docs/UI_DESIGN_KNOWLEDGE_BASE.md`](docs/UI_DESIGN_KNOWLEDGE_BASE.md): Apple client layout, native controls, messages, composer and row contracts.
- [`docs/design/MOBILE_UI_REWORK_BRIEF.md`](docs/design/MOBILE_UI_REWORK_BRIEF.md): Mobile visual review and screen acceptance.
- [`docs/design/IOS_OPTIMIZATION_PROGRAM.md`](docs/design/IOS_OPTIMIZATION_PROGRAM.md): End-to-end client performance and read-only diagnostic entry.
- [`docs/PERFORMANCE_KNOWLEDGE_BASE.md`](docs/PERFORMANCE_KNOWLEDGE_BASE.md): Performance, caching, load, offline data and profiling.
- [`docs/troubleshooting/TROUBLESHOOTING_INDEX.md`](docs/troubleshooting/TROUBLESHOOTING_INDEX.md): Symptom-specific device, connection, conversation and rendering investigations.
- [project.yml](project.yml): 改 target / 签名 / 扩展嵌入前先看 XcodeGen 规格.
- [scripts/ios_sim.sh](scripts/ios_sim.sh): 模拟器 / 真机构建、测试、安装启动.

## 工程要点

| 项 | 约定 |
|---|---|
| 最低系统 | iOS 17；Mac 客户端 macOS 26 |
| 语言 | Swift 6，默认 `MainActor`；NSE / XCTest 目标显式 `nonisolated` |
| UI 状态 | `@Observable`，禁止 Combine `ObservableObject` |
| Dependencies | SwiftTerm (MIT, pinned release) powers the Mac agent terminal and both clients' project terminal. Sparkle (MIT, pinned release) is linked only by the direct-download Mac target for software updates. Encryption uses CryptoKit. |
| Bundle | `com.x0c.corral`（iPhone 与 Mac 同一个）/ NSE `com.x0c.corral.nse` |
| Mac 签名 | Developer ID Application 手动签名 + 加固运行时（调试与安装同一身份，钥匙串条目才不弹授权） |
| Mac 本机文件 | `~/.config/corral-mac/`（`AppStorageLocation`）；iOS 仍是 Application Support，不迁移 |
| Team | `SHZQ3MWP3B` |
| 钥匙串共享组（Swift 字面量） | `SHZQ3MWP3B.com.x0c.corral`（**不要**在源码里写 `$(AppIdentifierPrefix)`） |
| Git remote | `ssh://git@forgejo.caozc.top:2222/Max/corral-apple.git`（独立仓，与 `cli/` 分开） |

## 构建与真机

**禁止驱动本机指针去点模拟器或真机。** 用户正在用这台电脑，远程点按会抢走光标（2026-08-29 已发生）。启动、截已有窗口、单测可以；把窗口切到前台再点、模拟点击、拖动手势一律禁止。需要真人点的步骤留给用户。

**用户可见改动完成后必须立刻装到名为「iPhone Max」的真机。** 禁止只提交源码、只跑单测、或只装模拟器就算完成。装完必须用 `devicectl` 回读手机上的市场版本与构建号，确认已覆盖成刚编的那一版。需要真人点开会话时留给用户，但安装、启动、截已有画面、回读版本不得省略。

**真机当时装不上**：设备 `unavailable`、锁屏 Locked、`CoreDeviceError` 4016、无路由、不在同网等——**同一回合立刻**按全局 [个人装包架 AppShelf](~/.config/agentsync/docs/APPSHELF_INSTALL_SHELF_GUIDE.md) 把签好的 IPA 上传到 `https://apps.caozc.com`，让用户用 Safari 登录后点图标安装。禁止只写「等解锁再装」就收工；禁止推手机装 Tailscale。上架成功不等于手机已换上，汇报须分开写。

```bash
# 模拟器（只保留一个 Booted 设备；双运行时同开会导致 simctl 假死）
SIM_NAME="iPhone 17" scripts/ios_sim.sh build
SIM_NAME="iPhone 17" scripts/ios_sim.sh test

# iPhone Max（当前为 iOS 27）：必须走通用真机包，不能把这台手机当 xcodebuild 直接目标
CONFIGURATION=Release DESTINATION="generic/platform=iOS" scripts/ios_sim.sh run
```

若误用 `platform=iOS,id=<UDID>` / `name=iPhone Max` 直接构建，可能报 `Timed out waiting for all destinations matching the provided destination specifier to become available` 和 `The developer disk image could not be mounted on this device`。根因是本机 Xcode 26.3 的 SDK 低于手机系统，不是未配对。完整命令与验收见 [`docs/troubleshooting/2026-08-29-xcode26-ios27-device-install.md`](docs/troubleshooting/2026-08-29-xcode26-ios27-device-install.md)。

真机签名注意：

- 必须带推送能力；通配描述文件不够，要用 `-allowProvisioningUpdates` 生成 `com.x0c.corral` 专用描述文件。
- 命令行无 Xcode 登录账号时，用 ASC Team Key（`AuthKey_D7YQ9HD7D6`）鉴权，见 `scripts/ios_sim.sh` 环境变量。
- 模拟器没有 APNs；推送与通知扩展必须在真机验。

## Mac 客户端构建与运行

```bash
xcodegen generate
xcodebuild -project Corral.xcodeproj -scheme CorralMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .derivedData-mac -skipPackagePluginValidation build
open -n -g "$PWD/.derivedData-mac/Build/Products/Debug/Corral.app"
```

- SwiftTerm 自带构建插件，命令行构建必须带 `-skipPackagePluginValidation`，否则卡在插件信任校验；首次构建若报缺 Metal 工具链，跑 `xcodebuild -downloadComponent MetalToolchain`。
- 已装的 `/Applications/Corral.app` 与 Debug 版同一设备身份，但自 CLI 0.24.257 + Mac 0.3.8 起按进程区分，可同时在线；若又看到两者轮流「正在重连」，按远程知识库同名契约排查，不要退回「先退出已装版」。验收打开的分屏会写进与 TUI 共用的会话组，验完要把被改的组恢复原样。

- 设计（桌面优先：TUI 式分屏与会话组共享、聊天/终端切换）、各轮已实现范围与 Debug 验收启动参数见 [Native macOS client design](docs/design/MACOS_CLIENT_DESIGN.md#desktop-first-redesign-owner-requirement-2026-10-04-round-2)。同样**禁止驱动本机指针**：用启动参数打开要看的画面，再用窗口截图验收。
- macOS baseline A1 and distribution separation follow [Distribution and software updates](docs/design/MACOS_CLIENT_DESIGN.md#distribution-and-software-updates). Use `python3 scripts/publish-mac-release.py` on committed source for Developer ID archive/export, nested-signature verification, notarization/stapling, DMG, signed update ZIP/feed and anonymous publication. `--prepare-only` exports a runnable committed app; `--publish-prepared <receipt-directory>` finishes its publication. Run the long publication through `../cli/scripts/agent_workflow.py run --repo . --require-clean --background -- python3 scripts/publish-mac-release.py` so it survives the agent. Publication re-checks a clean working copy after notarization, so in the shared multi-agent workspace run it from a clone pinned at the release commit, or leave the live checkout untouched until it completes ([publication boundary](docs/PUBLIC_BUILD_GUIDE.md#publication-boundary)). Preparation logs and receipts are under `~/.config/corral/development/mac-releases/`. Store builds must exclude the updater entirely; they are not yet exposed as a target.

## 硬约束（产品行为）

1. **手机的聊天/画面镜像永不改托管窗尺寸（永不发 `screen.resize`）**：手机和电脑看的是同一个 tmux 窗格，镜像改尺寸会把桌面挤窄。显示助手原生终端的客户端（Mac 终端视图，以及将来上线的手机助手终端模式）与 TUI 窗口一起按「用户最近在用的那个客户端」定尺寸（2026-10-12 机主裁定，取代「最宽观看方」；`terminal.*` 带 `active`，见 Mac 设计文档 [Terminal size follows the client in use](docs/design/MACOS_CLIENT_DESIGN.md#terminal-size-follows-the-client-in-use-owner-decision-2026-10-12)）。
2. 事件流必须**多播**：会话列表、对话、终端可同时订阅，禁止单消费者抢包。
3. 推送密文字段名是 **`corral`**（base64）；明文开发机标识字段是 **`host_id`**，给通知扩展取公钥用。
4. 通知扩展要**自己编译**加密与钥匙串源文件，不能链主 App 二进制。
5. 用户可见文案走 `Shared/Resources/Localizable.xcstrings` 语义键（en + zh-Hans，两端共用）。**缺 key 构建不报错、真机直接显示 raw key**（2026-09-23：右上复制/接力菜单 9 个 key 漏加、`action.delete` 漏加，都是装机后才看到 key 原文）。改用户可见文案后先跑 `python3 scripts/check_localizations.py`（纯 Python，无需 Xcode/模拟器），红了先补 key 再装机。系统权限说明走 `iOS/Resources/InfoPlist.xcstrings`（en 源语言 + zh-Hans），Info.plist 里只放英文源文案。远程错误缺 message 时走 `error.unknown`，禁止写死「未知错误」。**聊天输入禁止再放 TUI 快捷键栏**（见 UI 设计知识库「输入区」）。
6. 助手配色与关注状态色以 CLI 为唯一来源，见 [`docs/UI_DESIGN_KNOWLEDGE_BASE.md`](docs/UI_DESIGN_KNOWLEDGE_BASE.md)。
7. **连接必须任意网络可达（对标 shell-gate）**：局域网与中继**并发抢答**（局域网约 2 秒、中继约 8 秒超时），先成功者胜出——智能选路就是「谁快用谁」，**禁止**按蜂窝/Wi‑Fi 粗暴关掉局域网（蜂窝上也可能有 VLAN/VPN/组网）。候选来自配对 `l=`、`hello.local_hints`、可选 Bonjour。重连与换网都必须重新抢答，**禁止**串行死等或死磕上次地址。配对一次即可。旧配对无中继/局域网地址时，在 `hello` 带回后写回 Host。界面须标明当前走局域网还是中继。**装上/启动、TCP 通了、Connecting 变成 Failed 都不算连上**；必须状态条已连接且开发机 `Currently online` ≥ 1。**抢答硬约束（2026-09-13 起，根因见远程知识库「一直 Connecting」踩坑）**：每路握手超时 / 取消必须**立刻**关 socket（`receive` 不响应 Task 取消，等它自己醒会拖到系统 TCP 超时几十秒）；仲裁只等第一个赢家，**禁止**用 TaskGroup 等所有路结束；输家、迟到赢家、过期一轮的赢家一律关掉；`adopt` 前先拆旧 socket；**禁止**再用「加超时 / 加闸门 / 改文案」治 Connecting——那五轮都试过，无效。开发机按「设备公钥 + 客户端进程标识 `ci`」只保留一条控制面：同一进程重连会取代自己的旧连接，同一台机器上的多份 App（已装版 + Debug 版）共存不互踢（每把设备公钥最多 4 条）；开发机 20 秒内不确认的通道会被踢。**本机 / 局域网不得出现 Connecting / 重连**：发送必须经每个平面唯一的有序发送队列，首次重连立即发起，本机开发机加抢回环地址；已连接后的短暂掉线在 1.5 秒内不改状态条、请求最多等 3 秒——这只用于掩盖已修好根因后的瞬断，不得拿来替代根因修复。契约见 `../cli/docs/REMOTE_KNOWLEDGE_BASE.md`「Same-machine and LAN connections never drop」。
8. **界面重绘已锁定方向后直接改代码**，禁止连环批量出效果图；细则见 UI 设计知识库「重绘工作流」。
9. **iPhone 原生助手终端（2026-10-14 机主要求，取代 2026-09-10 暂下线规则）**：会话详情通过右上角更多菜单内的原生选择项切换聊天 / 终端（同日机主修正），不设独立分段栏，复用 SwiftTerm UIKit 与 `terminal.*` 原始流；禁止重新启用旧 Canvas 字符格镜像。终端独占键盘，聊天输入区只在聊天模式出现；隐藏 / 后台停止终端订阅并撤尺寸票。尺寸遵循第 1 条最近使用规则；不发 `screen.resize`。项目 shell 仍是独立功能。完整行为与验收见 [iPhone agent terminal](docs/design/IPHONE_AGENT_TERMINAL_DESIGN.md)。
10. **iPhone 会话列表行普通字号固定等高三行**（Mac 侧栏不适用：桌面固定等高两行，见 [Mac 侧栏密度重绘](docs/design/MACOS_CLIENT_DESIGN.md#sidebar-density-redesign-owner-request-2026-10-05)）：标题一行、预览一行、项目+时间一行；标题长短与有无预览都不得改变行高，也不得预留空行。唯一权威见 [`docs/UI_DESIGN_KNOWLEDGE_BASE.md` 行高契约](docs/UI_DESIGN_KNOWLEDGE_BASE.md#row-height-contract)。2026-10-01 曾因后续改动放开两行标题 / 按内容定高而回归；预览缺失是 SessKit 数据问题，不得靠改行高处理。

## 目录地图

| 路径 | 用途 |
|---|---|
| `Shared/Core/` | 两端共享的纯 Foundation 层（协议、加密、连接、存储、对话/发送/时间线逻辑）；`Package.swift` 的可移植单测只覆盖这里 |
| `Shared/UI/` | 两端共享的 SwiftUI 界面与 `AppModel`；平台差异用 `#if os(...)` 与 `Shared/UI/Platform/` 适配 |
| `Shared/Resources/` | 共用文案目录与共享颜色/助手官方标识（`SharedAssets.xcassets`） |
| `iOS/` | iPhone 外壳：入口、开发机列表、会话列表页、扫码配对、推送、项目终端、原生助手终端 |
| `macOS/` | Mac 外壳：主窗口、侧栏、检查器、配对、设置、菜单命令、`AppIcon.icon` |
| `Shared/Core/Network/RemoteClient.swift` | WebSocket、握手、RPC、重连、按通道多播 |
| `Shared/Core/Crypto/RemoteCrypto.swift` | 与 Python/Go 对齐的通道与推送加解密 |
| `Shared/UI/Design/` | 间距、配色、字体、助手标识 |
| `iOS/Assets.xcassets` | iPhone AppIcon |
| `NotificationService/` | 推送解密改写标题正文 |
| `Tests/` | 加密 / 配对 / 帧协议单测 |

## Mac debug process ownership

Before launching a newly built Corral Mac app for debugging or acceptance, terminate every existing Corral GUI app process, including installed Release and all DerivedData Debug copies. Match the Corral app executable path; do not terminate the CLI, remote host service or assistant sessions. Wait for the old app processes to exit before launching exactly one newest build. Verify the surviving PID, executable path, version/build and source commit before inspecting its window; stop and correct any mismatch. Coordinate this restart through TASKBOARD so concurrent tasks do not launch competing app copies. At delivery, close Debug copies and leave only the latest installed Release running. Multiple-client protocol compatibility does not authorize multiple local GUI app processes during this workflow.

## 验收清单（真机）

- [ ] 构建安装并启动
- [ ] 扫码或粘贴配对后重启仍在
- [ ] **换网冒烟**：蜂窝或不在开发机局域网时数秒内连上（走中继，状态条可见「中继」）；同网时抢答可走局域网（状态条可见「局域网」）；开关飞行模式/切网后应自动重选路
- [ ] 会话列表与电脑侧一致，分档与关注圆点正确（黄/绿/红与 CLI 一致）
- [ ] 对话：工具摘要、提问选项、底部状态条（原生聊天 / 终端切换，见硬约束第 9 条）
- [ ] 终端：中文输入、颜色、选择与粘贴正常；键盘 / 横竖屏适配、重连与电脑尺寸接管按终端设计验收
- [ ] 文本 / 附图两种输入（**无** TUI 快捷键栏）；弹出键盘后输入条贴在键盘上方、最新对话仍可见；连点发送不会重复发出；**新建会话成功后立刻进聊天并自动聚焦输入，不退回列表**
- [ ] 推送标题为解密后的真实文案；快捷回复能进会话
- [ ] 断线回前台自动重连；列表顶部连接状态可见
- [ ] 深浅色与中英文界面可读

## 领域地图（doc-init）

<!-- 覆盖度复核基线：2026-08-30 · iOS 组件本地地图；产品总图见 ../AGENTS.md -->

| 领域 | 入口锚点 |
|------|---------|
| 网络与远程协议客户端 | Shared/Core/Network/RemoteClient.swift · Shared/Core/Crypto/RemoteCrypto.swift |
| 界面与设计令牌 | Shared/UI/Design/ · Shared/UI/ · iOS/Views/ · macOS/ · docs/UI_DESIGN_KNOWLEDGE_BASE.md |
| 主机/会话状态 | Shared/Core/Store/ · Shared/UI/Sessions/HostSessionFeed.swift |
| 推送通知扩展 | NotificationService/ |
| 性能与重连 | docs/PERFORMANCE_KNOWLEDGE_BASE.md · Shared/Core/Network/ |
| 真机构建与安装 | scripts/ios_sim.sh · project.yml · docs/troubleshooting/ |
| 远程协议契约（跨仓） | ../cli/docs/REMOTE_KNOWLEDGE_BASE.md · ../cli/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md |

## 待补充知识库（doc-init backlog）

（当前无待补充项；中继运维见 agentsync 基础设施知识库 `corral-relay.caozc.top` 节。）
