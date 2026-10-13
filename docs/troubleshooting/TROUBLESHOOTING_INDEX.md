# Apple 客户端故障排查索引

排查手机或 Mac 客户端安装、运行、画面或远程会话异常时先读本索引。正文记录才是权威源；这里只做症状路由。

未命中下列触发词、只是改界面或普通功能时，不必读本目录。

| 现象 / 触发词 | 权威源 |
|---|---|
| Mac aborts in AttributeGraph from the sidebar List (0.3.61 on selection; 0.3.79 seconds after launch on macOS 26.7); `OutlineListCoordinator` → `ScrollViewHelper.didChangeProperties` → `NSScrollView tile` → nested `NSHostingView.layout` | [Mac scroll indicators](../design/MACOS_CLIENT_DESIGN.md#mac-scroll-indicators-owner-correction-2026-10-08) (SwiftUI List owns its scroller style and reverts overrides inside its update; overlay comes from the process-only preference set at launch, never from mutating the List; reproduce with the process-local `-AppleShowScrollBars Always` argument; remote crash evidence is separate from local updater quits) |
| Mac/iPhone chat rendering traps in `ChatImageReference.normalize`, `trimmingCharacters` or Swift string-index validation; fenced Unicode before image paths | [2026-10-11-chat-image-reference-unicode-crash.md](2026-10-11-chat-image-reference-unicode-crash.md) (original-string range ownership; shared image parser) |
| Mac CPU 占满、窗口缩放卡死或闪退、`NSGenericException` 提示过多 Update Constraints passes | [2026-10-05-mac-layout-loop.md](2026-10-05-mac-layout-loop.md)（原生导航和检查栏的尺寸协商循环；活动点动画也有单独的空闲 CPU 修复） |
| 构建报 `missing Metal Toolchain` / `cannot execute tool 'metal'`、刚才还能编、系统 Xcode 被切到 beta | [2026-10-07-xcode-select-beta-missing-metal.md](2026-10-07-xcode-select-beta-missing-metal.md)（按命令设 `DEVELOPER_DIR` 指向装有 Metal 组件的 Xcode，不改全局 `xcode-select`） |
| `simctl` 安装/启动/截图卡住、同时开了多个 iOS 运行时模拟器 | [2026-08-08-simctl-hang-dual-runtime.md](2026-08-08-simctl-hang-dual-runtime.md) |
| iOS 27 真机在 Xcode 26.3 上无法直接构建、开发支持文件挂载失败、需用通用真机包安装 | [2026-08-29-xcode26-ios27-device-install.md](2026-08-29-xcode26-ios27-device-install.md) |
| 改完手机端源码但 the paired iPhone 仍是旧版、真机过滤/界面与刚改的不一致、**不得只提交不安装** | [2026-08-29-xcode26-ios27-device-install.md](2026-08-29-xcode26-ios27-device-install.md) |
| 通用真机包已经编过但装不上、`No route to host`、设备变成 `unavailable`、要不到电源断言 | [2026-08-29-xcode26-ios27-device-install.md](2026-08-29-xcode26-ios27-device-install.md)（包已成功；通道掉了，点亮/解锁或插线后只重装，不重编、不改回直连目标） |
| 真机包显示已安装但 App 打不开、脚本退出码 1、`Locked`、`Unable to launch … device was not, or could not be, unlocked` | [2026-08-29-xcode26-ios27-device-install.md](2026-08-29-xcode26-ios27-device-install.md)（安装已成功，启动被锁屏拦住；用 `info apps` 回读版本，解锁后再单独拉起，禁止当安装失败去重编） |
| 装完启动停在对话中间转圈、第二次进列表仍先空白、搜索后退出列表被搜到的行替换 | [PERFORMANCE_KNOWLEDGE_BASE.md](../PERFORMANCE_KNOWLEDGE_BASE.md)（列表快照；对话转圈不是列表失败） |
| 换网后对话像重新加载整段历史、重连后聊天闪空、断线期间的新消息看不到、再开同一会话先空白再回填、离线看不见刚看过的对话 | [PERFORMANCE_KNOWLEDGE_BASE.md](../PERFORMANCE_KNOWLEDGE_BASE.md)（对话尾部缓存；按序号补缺口；空 replay 不是清空；画面不按序号回放）。契约见 `https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md` §4.3 / §7.2 |
| 刚开的会话发了「在吗」或第一句、自己的气泡有了、助手回复一直不出现、电脑终端里已经有字、长连接还活着 | **不是** 已修好的长连接假在线。正式历史在转正时一次性出现，服务端读进缓存却没推到手机仍在听的旧通道。权威源 [REMOTE_KNOWLEDGE_BASE.md](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md) 踩坑「刚开的会话发了在吗」；契约见 `https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md` §4.3 第 4 条。禁止当成 protobuf 没字，禁止先改手机，禁止让用户退回重进 |
| 手机发得出话但对话气泡不出现、看不到助手回复、退出重进才补上、再发送提示 `This session is no longer in the list` / 「这条会话已经不在列表里了」 | 退出重进能补上 = 推送链路断了（长连接假在线 / 读取游标被抢 / 没有本地气泡），不是解析器没字。权威源 [REMOTE_KNOWLEDGE_BASE.md](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md) 踩坑「发得出、对话不更新」；契约见 `https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md` §4.3 与 §4.3.1。刚开的新会话自己那句已经在、助手没有——先看上一行。禁止让用户退回列表重进当修复 |
| 对话在刷但之前的选择题还卡在底上、两道题合成一排 8 个选项、问卷跟新气泡叠在一起 | 推送通了，当前提问口径错了：多道题被摊平，且过期问卷仍钉底。权威源 [REMOTE_KNOWLEDGE_BASE.md](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md) 踩坑「选择题还卡在底上」；展示约定见 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「提问选项」。禁止把「对话在刷」当成问卷没问题 |
| 进会话详情后点返回没反应、看不到助手正文、打开大历史像卡死、**Pi 会话聊天是空的** | [2026-08-29-mobile-detail-back-and-missing-agent.md](2026-08-29-mobile-detail-back-and-missing-agent.md) |
| 气泡里 Markdown 没渲染、看得见 `###` / `- ` / `|---|` 原文、标题列表表格像纯文本 | [2026-09-11-chat-markdown-block-raw.md](2026-09-11-chat-markdown-block-raw.md)；产品口径见 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「气泡 Markdown」 |
| 进入会话详情消息整体偏左贴边、滚动之后左右边距才恢复 | **Must read** [Initial conversation margins](../UI_DESIGN_KNOWLEDGE_BASE.md#initial-conversation-margins). Verify the initial horizontal offset before any keyboard or scroll interaction. |
| 进会话中间一条 Working 横条、进去会话半屏转圈、运行中白条居中、点进正在跑的会话布局乱 | **Must read** [Conversation composition](../UI_DESIGN_KNOWLEDGE_BASE.md#conversation-composition). Working/waiting live only in the activity cue above the composer (not the header, since 2026-10-01). A hugging status strip plus the loading spinner is centered in the expanding pane. |
| Mac 点开会话白屏、对话区一片空白、滚动一下消息就出来了 | [2026-10-13-mac-chat-blank-until-scroll.md](2026-10-13-mac-chat-blank-until-scroll.md)（整段换窗后懒加载列表停在估算偏移、没有生成行；按测得高度重新锚定最新条；不是渲染慢，别加后台预渲染） |
| Mac 对话里回复下面一大块空白、空白夹在回复和下一条提问之间、打开会话没触底且右下有回到最新箭头 | [2026-10-05-chat-blank-band-under-reply.md](2026-10-05-chat-blank-band-under-reply.md)（Mac 气泡文字用同一套 TextKit 1 量高与绘制；禁止退回 TextKit 2 或 boundingRect 量高） |
| 发完消息会话白屏、消息跑到屏幕上面外面、下拉恢复 | **Must read** [Send white-screen](../UI_DESIGN_KNOWLEDGE_BASE.md#send-white-screen-2026-09-14). 发送滚到布局锚定的最新条目；无溢出时禁止滚原始底边。 |
| 键盘没顶起输入框、输入条被挡住、弹出键盘后无法键入或点击、输入框飞到顶部状态栏、重构键盘输入区 | **Must read** [keyboard troubleshooting](2026-08-29-chat-keyboard-does-not-lift.md) and [conversation input contract](../UI_DESIGN_KNOWLEDGE_BASE.md). Native safe-area ownership replaces height probes and delayed scroll compensation; otherwise invalid geometry can move the composer offscreen. |
| 聊天输入上方又出现 Esc / Tab / Ctrl / Alt / 方向键一排、键盘工具条挡对话 | 产品约定在 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「输入区」：聊天**禁止** TUI 快捷键栏。删掉即可，不要改成可开关 |
| 新建会话成功后只退回列表、没有立刻进聊天、还要自己再点一行、进了聊天还要再点输入框才出键盘 | 产品约定在 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「主界面结构约定」第 9 条。创建成功必须关掉表单、推进该会话聊天页并自动聚焦输入；禁止只 `patch` 列表就结束 |
| 刚发的那句排在助手后面、退出 App 重进又正常、自己先说的话跑到时间线末尾 | 本地气泡排序：见 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「发送互斥」本地气泡位置、[`../PERFORMANCE_KNOWLEDGE_BASE.md`](../PERFORMANCE_KNOWLEDGE_BASE.md)。禁止再把所有负序号甩到正式消息后面 |
| 手机列表时间/预览比 TUI 旧（TUI 刚刚、手机 19m ago）、手机绿点比 TUI Active sessions 多很多 | [2026-09-10-session-list-time-not-start.md](2026-09-10-session-list-time-not-start.md)「2026-10-01」节（圆点由开发机按 TUI 同一规则下发 `marker`，禁止按 live 画绿；时间同规则，差异是数据陈旧，可见列表每 20 秒校验兜底，触发点未复现） |
| 列表「N 分钟前 / just now」像开会时间、和电脑侧栏对不上、以为手机用了创建时间 | [2026-09-10-session-list-time-not-start.md](2026-09-10-session-list-time-not-start.md)；产品口径见 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「列表时间」。先对同一条会话两边对照，禁止改成首条/创建时间 |
| 白天/浅色模式助手气泡看不见（只剩字）、黑夜正常；用户或助手消息都只显示一行、长文被裁 | [2026-09-11-light-mode-bubble-and-single-line.md](2026-09-11-light-mode-bubble-and-single-line.md)；令牌与可选正文见 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)。禁止退回 `.textSelection`，禁止写死浅灰 hex |
| 手机一直 Connecting / Connection failed、开发机 status 在线数为 0、同 Wi-Fi 仍连不上、TCP 通了却没握手、装上了仍卡 Connecting | [REMOTE_KNOWLEDGE_BASE.md](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md) 踩坑「一直 Connecting / Connection failed」。TCP 通 ≠ `online≥1`；装上/启动不算连上。**根因是连接泄漏不是超时**（手机输家 socket 不关拖住赢家 + 开发机僵尸通道占满 8 个名额），iOS 1.0.49 (59) + CLI 0.24.210 已修；复发先查 `lsof :8737` 来自手机的条数（应为 2）与 events.log 的 `unconfirmed_expired` / `superseded`，禁止再加超时/闸门补丁 |
| 手机在外网一直 reconnecting、开发机中继在线但 `Currently online` 无 iPhone、完成/等待推送仍能收到、关掉手机 VPN 就好 | 手机 VPN 拦住了到中继的长连接（APNs 能到不代表中继能到）。先关手机 VPN/代理后杀掉重进；配对有效，不用重扫。判别：`corral remote status` 中继 online、`events.log` 只有成对 detach、无新 attach，且同期有 `remote_push_sent` |
| 短用户气泡变成横条大按钮、上下大片空白、聊天气泡布局全乱、怀疑改气泡高度改坏了 | 产品口径见 [`../UI_DESIGN_KNOWLEDGE_BASE.md`](../UI_DESIGN_KNOWLEDGE_BASE.md)「超长气泡内滚动」。根因多为 `GeometryReader` 包气泡正文；短气泡必须 hug，超长才按屏高 50% 封顶内滚 |
| 完成通知收不到、Release 包推送全丢、推送环境 sandbox/production 对不上 | [2026-09-30-push-environment-entitlement.md](2026-09-30-push-environment-entitlement.md)（env 必须按签名派生，禁止 `#if DEBUG`；取不到就跳过上报，不许硬写 production） |
| 通知能收到但点进去是空白 No sessions、新会话通知点进空页 | [2026-09-30-notification-tap-blank-sessions.md](2026-09-30-notification-tap-blank-sessions.md)（session 腿禁止为未知 key push 路由；等整窗快照，缺席才 consume 给明确恢复） |

远程协议、压缩、消息窗口和断线恢复的架构约束见 `https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md`。

<!-- 该文档整理/压缩于 2026-09-05 -->

- [Simulator markdown table crash](2026-09-14-simulator-markdown-table-rewrite-crash.md): read when the simulator repeatedly reports Corral quitting during Markdown table tests.
