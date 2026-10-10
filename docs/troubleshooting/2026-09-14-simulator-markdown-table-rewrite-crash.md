# Simulator “Corral quit unexpectedly” flood (markdown table rewrite)

## 现象

Mac 连续弹出 **Corral quit unexpectedly**。崩溃记录在 `~/Library/Logs/DiagnosticReports/Corral-*.ips`，进程路径在 **CoreSimulator** 下的 `Corral.app`，父进程是 `launchd_sim`，不是 iPhone 真机上的包。

常见伴随：

- 每约 30 秒一条新崩溃（XCTest 宿主反复拉起）
- 栈在 `ChatMarkdown.rewriteTables` → `AttributedString.replaceSubrange` → `CollectionsInternal`（`EXC_BREAKPOINT` / `SIGTRAP`）[stale as of 2026-09-29：表逻辑已迁入 `ChatMarkdown.applyBlockStyles`，`rewriteTables` 不再存在；此处保留事发当时的栈形态]
- 测试名常为 `ChatMarkdownTests`（例如 `testTableCellEmphasisSurvivesRewrite`）[stale as of 2026-09-29：该用例名已不存在；现行对应覆盖在 `ChatMarkdownTests.testHeadingsListsAndTablesBecomeVisibleStructure`]
- 本机留着卡住的 `xcodebuild test` / `simctl diagnose`

## 根因

窄屏表格改写成纵向卡片文本时，单元格正文从原 `AttributedString` 切片取出后仍可能与原文共享 CoW 存储。再把卡片拼回去时走 `replaceSubrange`，在单元格含粗体 / 行内代码等 inline run 时，Foundation 在内部集合上断言失败，测试宿主进程直接崩。Mac 把模拟器里的宿主当成 “Corral” 弹系统崩溃窗；测试若卡住重试，就会刷屏。

这不是内存不足，也不是中继 / 真机安装包问题。

## 修复

- 单元格与卡片替换文本经 `NSAttributedString` 深拷贝，断开与原文的存储别名。
- 用「前缀 + 卡片 + 后缀」重建整段，禁止对表格区间调用 `replaceSubrange`。
- 排查时先 `xcrun simctl shutdown all` 并杀掉卡住的 `xcodebuild test`，立刻停弹窗；再修代码。

## 禁止的误修

- 不要关掉模拟器崩溃对话框当「修好了」却留下挂起的 `xcodebuild test`。
- 不要把弹窗当成真机 App 闪退去改配对 / 中继。
- 不要为躲断言退回 `.inlineOnly*` 或关掉表格改写——标题/列表/表格原文会重新露出来。
- 有真机验收 UI 时不要为跑库测试长时间挂着模拟器；单测跑完必须 `simctl shutdown all`。

## 验收

- `ChatMarkdownTests` 整组通过，尤其含粗体 / 行内代码单元格的用例。
- 跑完后无 Booted 模拟器，且不再新增同栈 `Corral-*.ips`。

<!-- 该文档整理/压缩于 2026-09-29 -->
