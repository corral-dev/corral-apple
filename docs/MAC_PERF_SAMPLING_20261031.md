# Mac 性能基线采样 + 优化（2026-10-31）

> 状态：基线收集中，非验收结论。只读采样为主；单开测量已做两轮（§5/§6）；§3.1、§3.4 已实施待门禁。
> 覆盖：启动耗时分布、会话切换、列表/对话加载、终端渲染、内存。

## 1. 现网快照（未控负载的过程观察，非基线结论）

> 方法学 review（2026-10-31）纠正：以下均为同进程连续读，未控 workload（pane/mode/历史长度/streaming/并发客户端未记录），
> 两次 `footprint` 读数相差 4MB 仅为进程内波动；不与 10-25 的 279MB 对比（不同 workload 不得 before-after）；
> 1 小时 TIME/ELAPSED 平均值已删（混合负载+采样附着膨胀，不可比）；`maxWait` 未按 method 拆前仅为未审计通道信号。

- App：`/Applications/Corral.app`，0.3.160 (165)，`ready + dataAttached`，多订阅，1 pending
- `client_diag status --active`：`slowWaits` 13 次，`maxWaitMs` 17.9s（待按 method 拆，并记录并发客户端数）
  - 取证修正（2026-10-31）：`maxWaitMs` 按知识库定义是 pending-registration→terminal-removal 的等待统计（含超时/teardown，不等于送达延迟）；
    保留 timeline 仅剩 1 条 `slowRequest`（1.1s，无 method 字段），其余被有界环形淘汰。单快照无法做按 method 归因——§3.4 已补 method 字段（见 §8），随下次发版生效，既往 `maxWait` 不可回溯
- 单开 Profile 测量状态（2026-10-31）：Release+DEBUG Profile 构建两次 `BUILD SUCCEEDED`（0.3.160/165，对齐源码，dSYM 齐），
  其间 `.derivedData-*` 被外部清空一次；disruptive 步骤已完成，见 §5/§6
- 全量重建：`.derivedData-mac-profile` 重建 `BUILD SUCCEEDED`，0.3.160/165，检验串 4 命中，dSYM 齐，二进制 md5 `0e43486c…`
- CPU：过程观察，瞬时 3%～41% 抖动（无界定窗口，不作结论）；正式基线需 20s 无采样窗口分场景测（idle 无详情 / 固定对话 / 活动终端前后台分离）
- 内存：同进程 `footprint` 283MB / 287MB 两次读
  - Malloc Small 181MB / IOSurface 40MB / Untagged 29MB / CoreAnimation ~7MB
  - `leaks`（现网 PID）：0 unreachable——181MB 系 reachable 持有，非泄漏
  - `heap -s`（`~/.config/corral/development/heap-summary-20261031.txt`，traced 90.9MB）：前排为 SwiftTerm cell 存储
    （`CellArena.attributes` 11MB/12 块 + `CellStoragePage` 0.7MB + `BufferLine` 数组 0.5MB，源码属 SwiftTerm 静态链入）与框架自有
    （SwiftUICore `PropertyList.Element` 6.3MB、Swift 元数据 6MB、CoreText CTRun 2.4MB + NSCTFont 1.5MB、
    SwiftUI AnyTrackedValue 字典 2MB、闭包上下文 ~1.7MB）；无 Corral 自有巨型缓存。
    结论：181MB 系长尾分散持有 + allocator 高水位，无单一 owner 可砍；本次 heap 即第一代 generation 证据
- 主线程 3s `sample`（`/tmp/Corral_2026-10-31_130139_TNHL.sample.txt`，单窗口定性提示，非热点百分比）：
  - 主线程栈约半数走 `CA::Transaction::commit → NSView display`，约四成进 Corral 绘制，下钻到 `NSAttributedString setAttributes → newWithDictionary → hashProbe`
  - Release 已 strip，`atos` 无符号，只能定到“文本属性应用”层；函数级归因见 §6

## 2. 代码路径审计（subagent 实测源码，file:line）

### 2.1 启动（cold-start）

- `macOS/CorralMacApp.swift:6-53` 入口，`AppModel.init:65-84`（`ChatMarkdown.prewarm` 已走后台 utility）
- `MacRootView.runFeed:509-667` → `HostSessionFeed.activate:60-83`（`loadPersisted:64` → connect → `startWatching:80 + refresh:81`）；668-688 为独立 helper（saved/persist/restorePanes），非 runFeed 一部分
- 首屏风险在列表快照同步读，不在 AppModel 初始化

### 2.2 列表首屏

- `Shared/Core/Store/SessionListStore.swift:506-544 rebuildSections`：每次全量 `filter + 3×sorted`，调用点 14 处（`searchQuery.didSet:45`、`refreshCalendar:86`、`loadPersisted:121,131`、`applyListResponse:160`、经 `applyListResponse:163 → replaceWindow:192/193` 间接、`patchSession:201`、`applySessionEvent:213`、`removeSession:244`、`markReadLocally:257`、`revealSession:292`、`replaceWindow:393`、`migrateSession:484,496`）；已加 `if built != sections` 守卫（见 §7）
- `loadPersisted:120 → SessionListCache.load:17-20 → readQueue.sync + Data(contentsOf:)+JSONDecoder`：读队列已与写队列分离（见 §7），MainActor 交错语义不变
- 写路径已对：utility 串行 + 250ms 合并（`SessionListCache.swift:56,70`）
- RPC 解码已在后台：`RemoteJSONDecoder.decodeOffMain`（`RemoteDecoding.swift:24-27`），经 `RemoteClientRPC.swift:26` 覆盖 `refresh` 的 `client.call:213` 与 watch 全量推送（`HostSessionFeed.swift:260-265`）

### 2.3 会话切换 / 对话渲染

- 切换剩余成本在 DisplayList 走查，不在 row body（§5 计数器 + §6 call-tree 双证）
- `ChatMarkdown.swift:17,33-41,51-66`：NSCache 256 条 / 8MB，16KB 上限转纯文本
- `MacConversationTextDocument.swift:222-223,531-541,608-675`：32 消息 / 64 宽度有界 detached 测量
- `SelectableAttributedText`：coordinator 24 宽度清缓存（iOS:205，Mac:651）
- 计数器位置：`ConversationStore:191-200`、`MacTextRowSwitchCounters:17`、`SwitchBodyCounters`（MessageBubble:56,112 / ToolActivity:60）

### 2.4 终端渲染（SwiftTerm 1.99.1，`project.yml:23-25`）

- `macOS/Terminal/TerminalEmulatorView.swift`、`StreamTerminalView.swift:48-56`、`RemoteTerminalStream.swift:610-611`
- 每个 `output` 直驱 `feedFromHost`，Corral 侧无合并；只有尺寸 150ms 防抖（`RemoteTerminalStream:451-470`）
- 隐藏终端仍收流只停画（`MacTerminalSessions.swift:4-10`），`stop()` 仅 close/replace/reset
- 界：scrollback 10000（SwiftTerm 默认，Corral 侧仅注释见 `TerminalHostFeed.swift:18`，无自有常量），backlog 4MiB，paste/OSC52 各 1MiB，input batch 8KiB
- SwiftTerm 1.99.1 已在内部合并 damage（历史测量：120 feeds → 7 invalidations）；Corral 侧再合并只能省 VT-parse 入口，不省绘制——需真实流式窗口只读 sample 定量后再定（§3 候选，已有 §6 方法）

### 2.5 搜索

- `macOS/Search/MacFulltextSearch.swift:83-93`：50ms debounce，无 pre-timer IO；`FulltextSearchStore.swift:63-91`：`search.fulltext top:40` ×3 重试（200/400ms sleep）
- 打开未缓存 key 走 `session.get`（`MacWorkspace.swift:344`）+ `revealSession`（`:321`，内部调 `rememberOpened`，`SessionListStore.swift:289`），范围 `MacWorkspace.swift:316-352`；持久化成本在 open 不在 query timer

## 3. 优化方向（按收益排序，未验证不承诺数字）

> 风险 review（2026-10-31）约束已合入：任一条都不重提 pooled-table（已否决）；Shared 改动需双端验收；原生 pane/view/text 归 primary，不进 OpenCode 非 UI 切片。

1. **列表**：~~`rebuildSections` 加相等守卫 + 后台过滤排序~~守卫已实施并验收（见 §7）；后台 filter/sort 与完整 `loadPersisted` 异步化**已证伪关闭**（2026-10-31）：真实 115 会话快照 load+decode 仅 0.6ms，无可测收益
   - 约束：`SessionListStore` 属 Shared → 双端集成构建+验收；TUI 无此功能不碰；守卫须保留 host/client 作用域与身份规则；后台记账不发 Observation 通知（均满足，见 §7）
2. **对话文本属性批量应用**：~~sample 热点 `setAttributes → newWithDictionary` 高频~~ **已用定量证据杀掉（2026-10-31）**：
  Profile 单开，130MB cursor ended 会话（`cursor:d9207816…`），launch 起 25s 全覆盖 sample
  （`/tmp/Corral_2026-10-31_164359_rDfI.sample.txt`，dSYM 符号化；对照组为 ready 后 25s 空闲 sample），
  加载确认（107 responses / 4 subs / maxWait 529.5ms）：Top 全是 SwiftUICore/AttributeGraph/AppKit layout，
  **无 ChatMarkdown、无 `setAttributes`、无 TextKit、无 JSON decode 帧（≥5 阈值，25s 窗口）**。
  结论：有界首绘分片 + NSCache + 后台解码成立，`setAttributes` 在首绘路径不存在可优化量；
  最初 3s 短采的 `setAttributes` 系误归因（strip 二进制 + 混合 workload）。本项关闭，不动手
   - 约束：最高风险项；动 `Shared/UI/Chat` → 双端验收（Mac uncapped 与 iPhone capped 路径分开验）；像素级一致；不换 renderer、不拆容器藏功
3. **终端 feed 合并**：~~等真实流式窗口只读 sample 定量~~ **已用定量证据杀掉（2026-10-31）**：
  只读 20s sample（`/tmp/corral-term-stream.sample.txt`，dSYM 符号化），窗口内含 5 次 terminal snapshot reset + attach 抖动；
  全聚合零 SwiftTerm/VT/parse/`terminalFeed`/BufferLine 帧（≥5 阈值），仅 1 帧 QuartzCore 合成。本项关闭，不动手
   - 约束（已归档）：只合并不节流；保 I/O 排序与 input echo、保 host 12ms 合并边界、不新增隐藏订阅/size vote；不碰 scrollback/backlog/paste 上限
4. **慢 RPC 归因**：已实施（见 §8）：`slowRequest` 自带固定 RPC 词汇；归因跑与计时跑分离
5. **内存**：`heap -s` 第一代证据已出（见 §1）：无 Corral 自有巨型缓存，维持“不动”；SwiftTerm cell 存储 12MB 属 emulator 自有界，由上游设计约束
   - 约束：只驱逐可重建缓存/dormant pane；不动 400 条快照预算、不砍 scrollback

## 4. 显式未做 / 限制

- iPhone 真机不可用：一切 Shared 改动的手机侧只到 signed generic 构建门禁，物理交互验收欠着
- TUI 无改动（独立 Python 路径；同类行为已逐项对照，无此三处缺陷）
- `sample` 附加膨胀 2–4×：定时跑与采样跑分离执行，未混用数字
- 历史 pooled-table 已被机主否决（见 PERFORMANCE_KNOWLEDGE_BASE §pooled withdrawn），不重提
- 正式基线重做清单（before-after 前必须）：任务自有 `Release+DEBUG` profile 构建，杀光 GUI 后单开持锁跑；
  固定 session + `-CorralInspectConversation`；定时与采样分离；`ConversationStore` 无工作即丢弃；
  分 workload；`footprint` + 无采样 CPU 分开报
- 单开测量恢复步骤（重做时重占 maintainer coordination board）：`xcodegen generate`（project.yml 新于 pbxproj 时必须）→ Profile 命令重建 →
  验版本 + `strings | grep CorralInspectSessionSwitch` + dSYM → 删 `/tmp/corral-mac-session-switch.json` →
  冷启动 ×3（`open -n -g` + `client_diag status --active` 轮询新 clientRun ready，脚本 `/tmp/corral-startup-time.py`）→
  切换检验（`-CorralInspectSessionSwitch -CorralInspectSessionSwitchNoForce`，JSON 24 条稳定 10s，跑两遍）→
  pkill Profile → `open -g /Applications/Corral.app` → `status --active` 回读版本 → 删 maintainer coordination board 行

## 5. 单开实测（2026-10-31，Profile 0.3.160/165 Release+DEBUG，单 GUI，无采样附着）

> 方法：冷启动 `open -n -g` → `client_diag status --active` 轮询新 clientRun ready+dataAttached；切换用
> `-CorralInspectSessionSwitch -CorralInspectSessionSwitchNoForce`，JSON 稳定（24 条）后取 warm（cycle>0）中位数，跑两遍。
> insp 数据：`/tmp/corral-mac-session-switch-run1.json` / `run2.json`。

- 冷启动 launch→ready：3.0 / 5.8 / 3.6s（3 次，含连接+数据面 attach；快照首绘在此之前）
- 会话切换 warm 中位数（maxMainStall / firstVisible / display 三者基本重合）：
  - run1：1 pane 68.0ms / 2 pane 116.0ms / 4 pane 149.0ms
  - run2：1 pane 106.0ms / 2 pane 119.0ms / 4 pane 173.0ms
  - run 间漂移大于知识库旧经验（~10ms），机器负载未控，不合并、不宣称改善/回归
- 归因：两 run warm 均为 rowMakes=0、timelineRebuilds=0、docRenders=0、bubbleBodies=0 —— stall 在 DisplayList/layout
- Profile 进程 footprint 141MB（检验 workload，与已装版不可比，仅记录）
## 9. Instruments 归因：切换失效源（2026-10-31，SwiftUI 模板 + Profile 单开检验）

> 方法：`xcrun xctrace record --template SwiftUI --attach` 覆盖 24 轮检验（1/2/4 pane），
> 导出 `swiftui-update-groups`（102,506 组，`/tmp/corral-update-groups.xml` 19MB）。
> 99.77% 行为空 cause（框架微失效噪声）；仅 114 组 ≥10ms，其中 8 组具名。

- 具名贵组（单个 UpdateGroup）：
  `MacWorkspace.open ← sidebar selectionBinding` 27.1ms；
  `ConversationStore.applySnapshot` 16.5ms；`markReadLocally ← MacPaneView.body` 10.5ms；
  `patchSession ← applySessionEvent ← applyMetadata ← handle` 13.3ms；
  `ConversationStore.handle` 22ms；`NSHostingView.setRootView` 链 17.1ms；scenePhase 20.8ms
- 关键区分：`open()` 同步 mutation 仅 0.6/12/6ms（检验 JSON `selectionMs` warm 中位数）——
  27ms 是该 transaction 引发的下游失效与布局，不是 mutation 本身
- `markReadLocally`/`applySnapshot` 均为一次性 transition（未读→已读首开 / 冷历史应用；warm 後 `isUnread` 守卫直接返回 false）——
  非 warm 切换常驻成本，不动手
- 结论：warm 切换的 Corral 侧 mutation 已是最优量级（~1ms/格）；40–150ms 在 DisplayList 传播。
  再往下只有缩小失效范围（更细 Observation 作用域），需新设计 + 机主拍板；行实现层无可动项
- `open()` 本体核查（2026-10-31，直读 `MacWorkspace.swift:291-313`）：仅数组/字典/序号操作；
  `requestKeyFocus` 只 bump 序号（composer 请求惰性求值），`focus()` 仅多格同组时发 layout RPC。
  27ms 全是下游传播。`metadataEpoch` 全局 bump 改 per-key 版本属 pooled-table 类结构改动——不碰，等拍板

## 10. Launch 全链路分段（2026-10-31，LaunchClock 进程原点 + 诊断时间线）

> 动机：外部 launch→ready 计时 3.0–5.8s 波动大，且含报告节流/首启 Gatekeeper 噪声；需内部锚点。
> 实施：`LaunchClock`（`CorralMacApp.init` 打点）+ `activate` 累计 snapshot/connect/list +
> `runFeed` 累计 ui/ready（含 pollAlive：区分 MainActor 调度延迟与真未就绪）+ `attachDataPlane` 自带 duration。
> 锚点：`Shared/Core/Diagnostics/ClientDiagnostics.swift`（`LaunchClock`、`stage` 字段、`record`/`diagnose` 透传）、
> `Shared/UI/Sessions/HostSessionFeed.swift`（`activate` 三段）、`macOS/MacRootView.swift`（`runFeed` ui/ready/pollAlive 轮询）、
> `macOS/CorralMacApp.swift`（`markLaunch`）、`Shared/Core/Network/RemoteClientLifecycle.swift`（attach 计时）。

- 实测（Profile 单开，0.3.160/165）：snapshot 496–652 / connect 666–922（race+hello 约 170–270ms）/
  list 687–943（watch+refresh 约 20ms）/ ui ≈list / ready 1166–1206
- `dataAttached` 自带 duration：27–52ms —— 500ms 级 ui→ready 缺口**不是**数据面握手
- pollAlive 分解：首次 poll 执行即已 ready（差值 0.1ms），287ms 缺口纯 MainActor 调度延迟——
  即 restored pane 首绘本身占着主线程。 **ready 信号晚，但用户界面不晚**
- 结论：launch→ready 内部真相约 1.2s（外部 3–6s 含报告节流 + 首启检查噪声，以内部锚点为准）；
  启动链无 Corral 热点（bootstrap 弥散、connect 网络界、bind 27ms、list 20ms）。
  后续证伪（2026-10-31）：真实 115 会话/128KB 快照 load+decode 仅 0.6ms（20 次均值）——
  `loadPersisted` 异步化最多省 1ms，不做；AppModel.init 诸项（UserDefaults/小 JSON/Keychain 读）均为毫秒级，
  相对 500ms+ framework bootstrap 无可测收益；push 双函数 macOS 侧为空实现。**启动方向无标的，关闭**
- 门禁：全量 portable EXIT 0、Mac universal + iOS generic 双 `BUILD SUCCEEDED`、0 error；已提交推送

## 6. Call-tree 归因（2026-10-31，Profile PID 90646 单开检验中 `sample 60s`，dSYM 符号化）

> 样本：`/tmp/Corral_2026-10-31_154946_HveT.sample.txt`，主线程 30711 栈；检验同期写满 24 条（1/2/4 pane 各 8 轮），sample 覆盖活跃切换。
> 采样膨胀 2–4×，只定性不定量。

- 全进程聚合 Top：`AG::Graph::update` 1562 / `update_attribute` 1504 / `input_value_ref_slow` 1243（AttributeGraph），
  `LayoutEngineBox.sizeThatFits` 889、`ModifiedElements.makeElements` 821、`ModifiedViewList.applyNodes` 671、
  `StackLayout.placeChildren` 290、`_FlexFrameLayout` 199/`_PaddingLayout` 185、`DynamicBody.updateValue` 139（SwiftUICore），
  伴随重 ARC（`_swift_release_dealloc` 795）与泛型元数据实例化。Top 列表无 Corral 帧
- 结论：切换 stall 是 SwiftUI view-graph 重建 + layout pass，随保留行数成比例；Corral body 已约零求值（§5 计数器亦证）；
  §3.2 的 `setAttributes` 猜测不适用于切换路径
- 含义：框架图节点数是剩余额度所在；合法杠杆只有缩小每次切换的失效范围（更少 transaction、更小 invalidation），而非行实现层优化

## 7. §3.1 实施与验收（2026-10-31）

> 范围：equality guard + 读写队列分离（`SessionListStore.swift:545`、`SessionListCache.swift:59-60,79-82`）；
> 完整 `loadPersisted` 异步化与后台 filter/sort 暂缓，理由见 §3。

- 回归：目标套件 45/45（含 2 新增：`testRedundantRebuildKeepsSectionsStable`、
  `testPendingSnapshotReadableWithoutFlush`），全量 portable 469/469，0 失败
- 语义修正（微实验证据 `/tmp/obsexp/obs`）：本工具链 `withObservationTracking` 对等值写不触发，
  知识库“Observation notifies on equal writes”在该观测通道不成立；守卫保护的是 SwiftUI 视图失效通道
  （历史 profiling 证其在等值写付出过整轮更新），回归测试断言值稳定性 + 真变更恰好一次通知（tracking 存活证明）
- 双端构建：Mac universal Release 0.3.160/165 + iOS generic Release 1.0.206/218（Apple Development 签名），
  均 `BUILD SUCCEEDED`，退出码 0/0；自有源码零新增警告（仅存量 ChatMarkdown NSFont sites）
- A/B 定量（2026-10-31，同一 `-CorralInspectSessionSwitchNoForce` 协议，24 轮/6 warm、无采样、无 xctrace）：
  pre-guard run1 68/116/149、run2 106/119/173；with-guard 87/111/91（离散：1 pane 67–96、2 pane 52–126、4 pane 84–159）。
  1–2 格落在 pre-guard run 间带内；4 格好 58–82ms，超出已见 run 方差，但 n=6 且候选 session 未钉死——
  suggestive，不 conclusive。**§3.1 的性能宣称降为 hygiene + 正确性（等值不打扰订阅者），实现与测试保留**；
  确证需钉死候选 + n≥18 的重跑，不在本轮追加打扰
- 机制终判（2026-10-31，新增 `sectionRebuilds/sectionSkips` DEBUG 计数器，同 ConversationStore 既有模式）：
  18 个 warm switch 仅 `sectionRebuilds: 2 / sectionSkips: 0`——真实使用中 rebuild 几乎每次都有真变化
  （live watch 事件持续 patch），guard 几乎无触发机会；同轮 warm 中位数 108/119/182（4 格回到 182，
  与 after-run 的 91 差 91ms——同二进制同协议，run 间漂移即是噪声本噪）。
  **§3.1 性能项正式关闭：hygiene 正确，零可测收益；4 格 91ms 判定为噪声，不再追**
- 物理验收未做：iPhone 真机不可用、Mac 单开窗口留给日常——signed 产物 + portable 全绿为当前证据边界

## 8. §3.4 实施与验收（2026-10-31，slowRequest 补 method）

> 动机：§1 的 `maxWaitMs 17.9s` 单快照无法按方法归因；本改动让每个慢等待自带固定 RPC 词汇，不断句、不记 params/payload。

- 实现：`ClientDiagnosticRecord.method?`（Codable 新增可选字段，旧报告可解，回归测试证明）；
  `record()` 加 `method` 参数；`trackPending([id: method], slowAfterMs:)` 经 `pendingMethods` 并行表传递注册时方法名；
  `pendingRequests` 元组加 `method`（调用点仅 `entry.timeout/continuation/plane`，源码兼容）；
  `client_diag.py` events 行加 `method` 列（schemaVersion 不变）
- 自毁 bug 一枚已修：首版在完成分支读 `methods[id]`（恒 nil），改并行表后正确
- 回归：全量 portable **471/471**（+2：`testSlowRequestCarriesMethod`、`testOldRecordWithoutMethodDecodes`），0 失败
- 双端构建：Mac universal Release 0.3.160/165 + iOS generic Release 1.0.206/218，
  日志 `BUILD SUCCEEDED` ×2、0 error；产物时间戳新于全部源码改动（16:31/16:32 > 16:29）。
  注：包装 shell 被服务端重启杀掉，EXIT 回显行缺失，以上三项（测试计数行、SUCCEEDED 行、产物新鲜度）为替代证据；
  两产物均为本地构建门禁用签，非发版签名
- 物理验收未做（真机不可用）：signed 产物 + portable 全绿为当前证据边界；method 字段随下次发版生效，既往 `maxWait` 不可回溯归因
