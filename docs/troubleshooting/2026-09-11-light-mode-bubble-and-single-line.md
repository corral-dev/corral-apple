# 白天助手气泡看不见 / 消息只显示一行（2026-09-11）

## 症状

- **浅色模式**下助手消息几乎看不到气泡底（只剩文字贴在灰底上）；**深色模式**正常。
- 用户与助手气泡都**只显示一行**，长文被裁掉（1.0.34 起可滑动选中之后）。

## 根因

1. **浅色对比**：对话页底是 `systemGroupedBackground`。助手气泡误用 `secondarySystemBackground`——在浅色下与分组页底同灰，气泡「消失」；深色下 secondary 有抬升，所以还能看见。
2. **单行高度**：`SelectableAttributedText` 用透明 `Text` + `UITextView` overlay 测高。`UITextView` 在 `ScrollView` / `LazyVStack` 里不按提议宽度换行算高，整段塌成一行。

## 正确修法

1. `Palette.assistantBubble`（及同页卡片）改用 **`secondarySystemGroupedBackground`**（浅色白底衬灰页；深色仍抬升）。
2. 可选正文用 `UIViewRepresentable.sizeThatFits` 按提议宽度算换行高度，禁止再靠 overlay 里的 UITextView 固有高度。

## 禁止的误修

- 不要给助手气泡写死浅灰 hex 绕过系统色（深色会坏）。
- 不要退回 SwiftUI `.textSelection`（又只能整段菜单）。
- 不要把对话页改成 `systemBackground` 只为迁就错误的 secondary 令牌。

## 验收

浅色打开长对话：助手气泡白底可见；用户/助手长文完整多行。单测见 `MessageBubbleLayoutTests`。

<!-- 该文档整理/压缩于 2026-09-29 -->
