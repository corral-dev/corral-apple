# 会话列表「N 分钟前」像开会时间？（2026-09-10；追加 2026-10-01 / 2026-10-19）

## 结论

手机列表与电脑侧栏**同源**：都按会话最近活动时刻（扫描得到的活动时间）现算相对文案，不是创建时间。手机自 v1.0.20 起不再优先展示服务端绝对时钟串。本机 Cursor / Codex 近期会话抽样贴近最近更新，系统性偏差未复现。

## 排查顺序

1. 同一条会话对比电脑侧栏与手机列表：同档 → 手机没有单独用开会时间；感觉偏旧要查扫描侧活动时间（文件时间 / 元数据污染回退），两端会一起偏。手机整日固定显示 `09-10 15:12` 这类绝对串时，先查版本与列表缓存（见第 4 条）。
2. 超过一天退回 `MM-dd HH:mm`，先确认最后活动是否落在该日。
3. Cursor 气泡常无逐条时间，不要用聊天里看不见的消息钟点否定列表时间；列表跟的是会话元数据 / 文件活动时刻。
4. 手机仍显示绝对时钟串时，先核对版本是否 ≥ v1.0.20，再查是否连错开发机或列表缓存未刷新。

## 禁止

- 不要在手机端另接「首条消息时间」或「创建时间」字段，会与电脑侧栏分叉。
- 不要只改文案格式而对同一条会话不做两端对照。

## 2026-10-01：手机行比 TUI 旧、绿点明显更多

- **绿点（已定因并修复）**：手机在 attention 为空、`live` 为真（仅进程存在）时就画绿。TUI 用 `activity_board.resolve_active_marker`（waiting / working / unread，或托管且在 "just now" 窗口内活动）。CLI v0.24.250 + iOS 1.0.87 起宿主每行下发 `marker`，并纳入列表版本指纹，任何 marker 翻转（含过期）即推送；修复后真机 2 个绿点，与 TUI 一致。契约见 [UI 知识库](../UI_DESIGN_KNOWLEDGE_BASE.md#两端状态语义唯一来源) 与 [远程知识库](../https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md#message-images-and-provisional-working-2026-10-01)。
- **时间（数据陈旧，触发未复现）**：17:26 时手机显示 "19m ago" 而 TUI 是 "just now"，某行 17:26 显示 "54m ago"、17:29 显示 "13m ago"，整列表像是冻结在约 17:07–17:15 的快照；17:29 重开后台后恢复。已排除公式差异（两端同阈值、同一宿主 `mtime`、手机每 30 s 重绘）、指纹漏 `mtime`（实际包含）、扫描索引过期（消费方拒收 > 12 s 的索引）、列表根 `.task` 不退不复跑（[swiftyplace](https://www.swiftyplace.com/blog/swiftui-view-lifecycle-onappear)、[NavigationStack 生命周期](https://mehmetbaykar.com/posts/swiftui-navigationstack-view-lifecycle/)）。陈旧窗口内发生过两次重装（另一 agent 的崩溃修复构建，然后 1.0.85）与一次守护进程重启。
- **兜底（1.0.87）**：列表可见时每 20 s 用 `since_version` 复查，漏推送 20 s 内收敛；这是兜底，不是已证实的根因修复。
- 复发时记录时间、有无会话开关/重装/前后台，两端对照同一行并立即取 `corral remote status`。
- **证据缺口（环境改进项）**：`corral remote status` 只留最近 8 次手机请求，`~/.cache/corral/events.log` 截断在 256 KB（当时只剩 17:19 起），早期列表流量无法还原。改进项：按设备保留更长的有界 RPC 历史（method / 时间 / 平面 / unchanged|full）。

## 2026-10-19：Mac 显示钟点而非可读的相对时间

Mac 专用的 `MacSidebarMetrics.compactTime` 绕过共享相对时间格式化，侧栏与全文搜索都在用：当天显示钟点、更早显示短日期。机主要求「3 minutes ago」这类相对时间。改用 `SessionPresentation.timeLabel(for:now:)`，沿用其三分钟/小时/天阈值、本地化文案与更早日期回退；iPhone 行与 TUI 本来就同阈值。这是展示层漂移，与宿主活动时间陈旧、列表订阅数据无关；契约见 [Mac 行](../design/MACOS_CLIENT_DESIGN.md#desktop-first-redesign-owner-requirement-2026-10-04-round-2)。

验收：源码 `16fe0b6`，408 个可移植 Core 测试、本地化覆盖、Mac Debug 构建/静态分析与通用 Mac Release 归档导出通过。任务内原生渲染器编译未改动的生产 `MacSessionRow`，在 30 秒、3/30 分钟、1/23 小时、两天观测中英标签，浅/深色 340 pt 行无重叠。这是组件渲染，不是配对宿主或已安装窗口截图：采集机有录屏权限但会话锁定、唯一显示器非活动，一次有界唤醒未恢复绘制，两次后台检查无新画面，故已安装窗口与空闲搜索刷新外观未验收。iPhone 行 30 s 原生时间线与源码比对未改，无真机/TUI 截图。剩余编译诊断仍为 [性能知识库](../PERFORMANCE_KNOWLEDGE_BASE.md#compiler-diagnostics-2026-10-07) 中已逐条评估的 Markdown 原生属性与 no-AppIntents 项。

交付：Mac 0.3.135 (139)，源码 `16fe0b6`，已安装通用 Developer ID 导出；嵌套签名校验通过，安装/导出可执行 SHA-256 `247510941bdc0feaaff5fb222f5d07f21690facc8cf5da9004646c2cc48f6fa3`，进程 6768 报告 0.3.135/139、本地就绪、数据面已挂。App 与 DMG 通过公证，[Mac 0.3.135](https://github.com/corral-dev/corral-apple/releases/tag/mac-v0.3.135) 含 DMG、签名更新 ZIP 与 appcast，匿名整包下载与本地 SHA-256 一致（DMG `70d0c47be6237d28edbef1c7530b7bc2fd617b432ba330d41f5f6a37005df414`、ZIP `826008947aaf3cfb85e49bc8fb3b7ba5cac3896fe6e5d151c34989941a93f066`），签名 feed 与 Homebrew 发布完成，回执 `~/.config/corral/development/mac-releases/20261019-160933/receipt.json`。安装/连接与发布不能证明未取得的已安装窗口外观。

<!-- 该文档整理/压缩于 2026-11-15 -->
