# Simulator "Corral quit unexpectedly" flood (markdown table rewrite)

## 现象

Mac 连续弹出 **Corral quit unexpectedly**。崩溃记录在 `~/Library/Logs/DiagnosticReports/Corral-*.ips`，进程路径在 **CoreSimulator** 下的 `Corral.app`，父进程 `launchd_sim`，不是真机安装包。

- 每约 30 秒一条新崩溃（XCTest 宿主反复拉起）。
- 栈在 `ChatMarkdown.rewriteTables` → `AttributedString.replaceSubrange` → `CollectionsInternal`（`EXC_BREAKPOINT` / `SIGTRAP`）[stale as of 2026-09-29：表逻辑已迁入 `ChatMarkdown.applyBlockStyles`，`rewriteTables` 不再存在；此处保留事发当时栈形态]。
- 测试名常为 `ChatMarkdownTests`（如 `testTableCellEmphasisSurvivesRewrite`）[stale as of 2026-09-29：用例名已不存在，现行对应覆盖是 `ChatMarkdownTests.testHeadingsListsAndTablesBecomeVisibleStructure`]。
- 本机留着卡住的 `xcodebuild test` / `simctl diagnose`。

## 根因

窄屏表格改写为纵向卡片文本时，单元格正文从原 `AttributedString` 切片取出后仍可能与原文共享 CoW 存储；拼回卡片走 `replaceSubrange`，单元格含粗体 / 行内代码等 inline run 时 Foundation 在内部集合断言失败，测试宿主直接崩。Mac 把模拟器宿主当成 "Corral" 弹系统崩溃窗，卡住重试就刷屏。不是内存不足，也不是中继 / 真机安装包问题。

## 修复

- 单元格与卡片替换文本经 `NSAttributedString` 深拷贝，断开与原文的存储别名。
- 用「前缀 + 卡片 + 后缀」重建整段，禁止对表格区间调用 `replaceSubrange`。
- 排查时先 `xcrun simctl shutdown all` 并杀掉卡住的 `xcodebuild test` 止住弹窗，再改代码。

## 禁止的误修

- 不要关掉模拟器崩溃对话框当「修好了」却留下挂起的 `xcodebuild test`。
- 不要把弹窗当真机 App 闪退去改配对 / 中继。
- 不要为躲断言退回 `.inlineOnly*` 或关掉表格改写——标题/列表/表格原文会重新露出。
- 有真机 UI 验收时不要长时间挂着模拟器跑库测试；单测结束必须 `simctl shutdown all`。

## 验收

`ChatMarkdownTests` 整组通过，尤其是含粗体 / 行内代码单元格的用例；跑完无 Booted 模拟器，且不再新增同栈 `Corral-*.ips`。

<!-- 该文档整理/压缩于 2026-11-15 -->
