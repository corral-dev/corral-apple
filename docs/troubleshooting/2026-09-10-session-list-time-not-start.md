# 会话列表「N 分钟前」像开会时间？

## 症状

手机会话列表右侧相对时间（刚刚 / Nm ago / Nh ago，或超过一天的 `MM-dd HH:mm`）看起来像会话**开始**时间，而电脑端侧栏像最近消息时间。

## 结论（2026-09-10）

手机与电脑端侧栏**同源**：都按会话的最近活动时刻（扫描得到的活动时间）现算相对文案，**不是**会话创建时间。手机从 v1.0.20 起不再优先展示服务端绝对时钟串。

本机抽样：Cursor / Codex 近期会话的列表时间贴近最近更新，贴近创建时刻的系统性问题未复现。

## 排查顺序

1. **先对同一条会话**：电脑侧栏相对时间 vs 手机列表相对时间。两边同档 → 不是手机单独用了开会时间；感觉「偏旧」应去查扫描侧活动时间（文件时间 / 元数据污染回退），两端会一起偏。
2. **超过一天**会退回 `MM-dd HH:mm`，容易被当成「开会那天几点」；看是否其实是最后一次活动落在那天。
3. **Cursor 气泡往往没有逐条时间**，不要拿「聊天里看不见的消息钟点」去否定列表时间；列表跟的是会话元数据 / 文件活动时刻。
4. 若手机仍是绝对时钟串（如整天都是 `09-10 15:12` 这种），先核真机版本是否已覆盖到带相对时间的构建（≥ v1.0.20），再查是否连错开发机或列表缓存未刷新。

## 禁止

- 禁止为消这个疑虑在手机端另接「首条消息时间」或「创建时间」字段；会与电脑端侧栏分叉。
- 禁止只改文案格式却不去对同一条会话两边对照。

## 2026-10-01: phone row older than the TUI, and far more green dots

### Symptoms
- The phone showed this session as "19m ago" while the TUI said "just now"; the row's preview was the text from about 17:07 at 17:26. Other rows were stale by different amounts (one showed "54m ago" at 17:26 and "13m ago" at 17:29), consistent with the whole list frozen at a snapshot from roughly 17:07–17:15.
- The phone showed about ten green dots while the TUI Active sessions board and sidebar showed two.

### Dots: confirmed cause and fix
The phone painted green whenever attention was empty but `live` was true (a process merely existing). The TUI uses `activity_board.resolve_active_marker` (waiting / working / unread, or hosted and active within the "just now" window). Fixed in CLI v0.24.250 + iOS 1.0.87: the host sends that marker as `marker` on every list row (also part of the list version fingerprint; the refresh loop pushes when any marker flips, including expiry). On real data after the fix: 2 green markers, matching the TUI. Contract: [UI knowledge base](../UI_DESIGN_KNOWLEDGE_BASE.md#两端状态语义唯一来源) and [remote knowledge base](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md#message-images-and-provisional-working-2026-10-01).

### Times: same rule, stale data; trigger not reproduced
- Ruled out: different formulas (both clients compute relative time from the host `mtime` with the same thresholds and the phone re-renders every 30 s); the list version fingerprint omitting `mtime` (it includes it); the shared scan index serving old rows (consumers reject indexes older than 12 s); the list root's `.task` not re-running after returning from a conversation (SwiftUI cancels it on push and re-runs it on pop: [swiftyplace](https://www.swiftyplace.com/blog/swiftui-view-lifecycle-onappear), [NavigationStack lifecycle](https://mehmetbaykar.com/posts/swiftui-navigationstack-view-lifecycle/)).
- Context: two app reinstalls (another agent's crash-fix build, then 1.0.85) and a daemon restart happened inside the stale window; after a fresh launch at 17:29 the rows were current.
- Mitigation (1.0.87): while the list is visible it re-checks with `since_version` every 20 s, so a missed push converges within 20 s. This is a backstop, not a proven root-cause fix.
- If it recurs: note the time, whether a conversation was open/closed or the app reinstalled/foregrounded, then compare the same row on both clients and capture `corral remote status` immediately.

### Evidence gap (environment improvement item)
`corral remote status` keeps only the last 8 phone requests and `~/.cache/corral/events.log` is truncated at 256 KB (it held only 17:19 onward), so the earlier list traffic could not be reconstructed. Improvement: keep a bounded, longer per-device RPC history (method, time, plane, unchanged/full) for list-freshness forensics.

<!-- 该文档整理/压缩于 2026-09-29 -->

## Mac shows a clock instead of elapsed time (2026-10-19)

The Mac-only `MacSidebarMetrics.compactTime` had bypassed the shared relative-time formatter, showing a clock today and a short date for older days. Both the sidebar and full-text search consumed it. The owner requires readable elapsed time such as "3 minutes ago". Reuse `SessionPresentation.timeLabel(for:now:)`; retain its existing three-minute/hour/day thresholds, localized copy and older-date fallback. The iPhone row and TUI already use the same thresholds. This symptom is presentation drift, separate from stale host activity or list subscription data; see [the Mac row contract](../design/MACOS_CLIENT_DESIGN.md#desktop-first-redesign-owner-requirement-2026-10-04-round-2).

Verification: source `16fe0b6`, 408 portable Core tests, localization coverage, Mac Debug build/static analysis and universal Mac Release archive/export pass. A task-local native renderer compiles the unmodified production `MacSessionRow`, shared Core and current app resources. English and Chinese labels were observed at 30 seconds, 3/30 minutes, 1/23 hours and two days; light/dark 340-point rows were inspected with no overlap. This is component rendering, not a paired-host or installed-window screenshot. The capture host has Screen Recording access, but its session is locked and the only display is inactive/asleep; one bounded user-active wake did not restore drawing, and two background-client inspection attempts produced no new surface. Installed-window and idle-search refresh appearance therefore remain unverified. iPhone/TUI comparison confirms their existing relative formatters in source; the iPhone row's native 30-second timeline remains unchanged. No physical-phone/TUI screenshot is claimed. Remaining compiler diagnostics are the individually assessed Markdown native-attribute and no-AppIntents entries in the [performance knowledge base](../PERFORMANCE_KNOWLEDGE_BASE.md#compiler-diagnostics-2026-10-07); the time change adds none.

Local delivery: Mac 0.3.135 (139), committed source `16fe0b6`, installed universal Developer ID export. Strict nested-signature verification passes; installed/exported executable SHA-256 is `247510941bdc0feaaff5fb222f5d07f21690facc8cf5da9004646c2cc48f6fa3`. Active installed process 6768 reports 0.3.135/139, ready local transport and attached data plane. The application and DMG passed Apple notarization. The [Mac 0.3.135 release](https://github.com/corral-dev/corral-apple/releases/tag/mac-v0.3.135) contains the DMG, signed update ZIP and appcast; anonymous full-byte downloads match local SHA-256 (DMG `70d0c47be6237d28edbef1c7530b7bc2fd617b432ba330d41f5f6a37005df414`, ZIP `826008947aaf3cfb85e49bc8fb3b7ba5cac3896fe6e5d151c34989941a93f066`). Signed-feed and Homebrew publication completed. Receipt: `~/.config/corral/development/mac-releases/20261019-160933/receipt.json`. Installation/connection and publication do not establish the unavailable installed-window appearance.
