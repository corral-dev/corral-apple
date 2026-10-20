# Corral 移动端界面视觉重绘 Brief

## 用户意图

Refine the iOS client's layout, visual hierarchy, and interactions across the existing product. Preserve the native iOS direction and prioritize readable content, balanced spacing, clear actions, and accessible layouts. Validate the actual installed application on the available physical iPhone; installation and launch alone are not visual acceptance.

### Current refinement scope

- Deliver a cohesive visual composition across the list and conversation, not isolated spacing corrections. Establish hierarchy and proportions before implementation, and validate the combined result before replacing the user's running app again. A sequence of minor tweaks does not satisfy the requested refinement.
- The [adopted session-list filter/layout contract](../UI_DESIGN_KNOWLEDGE_BASE.md#session-list-filters-and-layout-2026-10-01) owns the compact device header, connection subtitle and two runtime/project filter rows. Session rows lead with the title; metadata is one quiet line; running is a single green dot (no extra “Live” word). Activity in chat is a hugging capsule, not a full-width card. The composer is a floating two-row card: text above, plus and send sitting on the bottom edge, with a visible gap above the keyboard. Its left and right edges align with the conversation bubbles. Text uses `Space.base` from the top and sides; the action row has no extra band under the buttons and `Space.sm` above them. Keep the empty card compact — do not stretch the field into a tall empty well. Tapping anywhere on the card focuses the field. Do not add ChatGPT-only search or voice controls.
- Do not leave the user's phone in a Debug inspection appearance (`-CorralInspectLight` / `-CorralInspectDark`) or with enlarged text. Restore the ordinary Release presentation after capturing screens.

- Include the conversation screen in the same refinement: navigation hierarchy, message spacing, activity summaries, and composer must form a consistent normal-size interface with the session list.

- Refine the normal everyday interface without enlarging the user's text or leaving the phone in an inspection appearance. Device inspection must restore the ordinary presentation immediately afterward; exaggerated text is not the requested visual direction.

- Keep connection status compact and visually subordinate to sessions, without a separate filled card.
- Do not retain a tall empty status section. Place the connection caption beneath the device name in the compact header; keep the two filter rows visible above the scrolling sessions, as specified by the adopted list contract.
- Give long titles priority over metadata; allow larger accessibility text to reflow instead of squeezing the title beside a timestamp.
- Present list previews as readable text rather than raw Markdown decoration. Keep source messages intact.
- Retain native list navigation, search, swipe actions, and all existing session semantics. The bottom search entry must look like a complete search field, not an isolated circular magnifier floating over the list.

## 目标

- 覆盖配对、开发机列表、会话列表、会话详情、对话、输入区、提问选项、连接中 / 断线 / 空状态等可到达页面。终端画面自 2026-09-10 起暂不上线（见 `UI_DESIGN_KNOWLEDGE_BASE.md` / `ProductFeatures.terminalPaneEnabled`），重绘验收不要把终端当必达页。
- 延续“系统原生 iOS 骨架 + 开发者工具气质”的既定方向，统一层级、间距、字体、颜色、圆角、图标和状态反馈。
- 优先消除影响观感和使用效率的问题：层级混乱、信息密度失衡、重复装饰、对比度不足、点击热区偏小、状态不易分辨、键盘遮挡和滚动收尾不自然。

## 不改变的行为边界

- 不改变扫码配对、远程接力、消息多播、重连和推送行为。
- 永不发送 `screen.resize`，终端仍与电脑共享同一 tmux 窗格宽度。
- 助手颜色与等待 / 运行 / 未读状态颜色继续以 CLI 为唯一来源。
- 保留中英文文案、系统深浅色、动态字体、降低动效和降低透明度的可用性要求；新增可见文案必须同步补齐英文与简体中文。
- 不通过批量生成效果图替代实现；视觉结构锁定后直接在 SwiftUI 中调整并截图验收。

## 验收口径

1. Capture the actual application before and after changes on the available physical iPhone, including light/dark appearance and larger text. Simulator use is allowed only when no paired physical device is available.
2. 真实走通启动、页面导航、会话打开、对话输入 / 发送等可用链路；终端入口须确认不可见。无法在本地构造的远程状态要明确标注未验证部分。
3. 运行项目既有测试与构建；检查无新增编译警告、无字符串键名泄漏、无布局裁切。
4. 在大字号、降低动效、降低透明度和中英文环境下复核核心页面。
5. 改动完成后用本 brief 与 `docs/UI_DESIGN_KNOWLEDGE_BASE.md` 反查，避免只优化单个页面而留下同类视觉问题。

## 会话时间线显示边界

- 聊天时间线只展示用户消息与助手消息。系统事件、内部协议记录、工具流转和其它非对话内容不得直接伪装成聊天气泡。
- 工具调用如果对用户有必要，应使用独立的可折叠工具区域；纯内部记录不进入聊天时间线。
- 验收时使用包含工具调用、状态变化和普通问答的真实会话，确认角色、顺序和内容边界都正确，不能只看空会话或静态预览。
- TUI 已有成熟的真人提问过滤语义：原始会话仍完整保留，面向人的预览才过滤运行时注入。远程手机客户端应沿用这条边界；跨 Python 与 Swift 不直接复制实现，而是由会话输出层统一裁定，手机客户端只做异常数据防穿透。

## 已验证的审计发现

### 手动配对输入的文案边界

- 现象：输入框提示“链接或代码”，粘贴命令行单独显示的配对代码后，实际报“配对链接无法识别”。
- 原因：手机客户端需要完整配对链接中的主机身份、密钥和中继信息；单独代码不包含这些信息，当前协议无法仅凭代码完成配对。
- 动作：界面只承诺支持完整配对链接，并补充短说明；不为了消除错误提示而伪造单独代码的协议支持。

## 已落地结论

- Search uses the native bottom toolbar on iOS 26 and later; older systems retain the native fallback. The UI design knowledge base owns the current search contract.
- 可见对话角色仅 `user`/`assistant`；工具进可折叠活动区；原始会话完整保留。
- 跨端共享契约与样例，不共享 Python/Swift 界面代码；手机保留防穿透。
- 浅色/深色/中文/配对失败/工具区/输入键盘已验；被观看终端实时画面仍需真机补验。

<!-- 该文档整理/压缩于 2026-10-20 -->
