# iOS 端到端专项优化纲领

优化对象是「手机操作 → 连接加密 → 开发机服务 → 会话/历史 → 回手机渲染」整条闭环，不是单页或单次请求平均耗时。界面、数据读取、协议、开发机服务、中继与真机验收可分工，但必须共用用户可感知指标。

## 1. 产品职责与边界

### 1.1 用户真正购买的结果

用户不是为了在手机上“浏览一份列表”，而是为了在离开电脑后继续掌控原来的工作：

1. **一次配对，跨网络可达**：在同一 Wi-Fi 下快速连接，换到蜂窝网络或其他 Wi-Fi 后自动尝试中继，不要求重新配对。
2. **看到正确上下文**：主机、会话、助手、消息和终端画面必须属于同一真实会话；不能因为缓存、切换主机或重连显示另一台机器的内容。
3. **先看到已有内容，再等新内容**：列表、对话和终端都应先使用本地可用内容，网络刷新在后台收敛；加载失败不能把已经看到的内容抹掉。
4. **输入产生可解释的结果**：发送、快捷回复、终端输入和停止操作要有立即反馈，不能重复发送，也不能让用户猜测请求是否成功。
5. **连接不打断工作**：切换网络、短暂断线、开发机暂时忙时，页面保留上下文并显示下一步；恢复后补齐缺口，不产生重复或静默丢消息。
6. **隐私边界清楚**：中继只能转发不可读的密文；手机上的配对凭据、推送内容和错误提示不能泄露会话正文或主机信息。

### 1.2 端到端链路

```text
手机界面
  ↓ 配对、列表、对话、终端、输入
手机连接与本地缓存
  ↓ 局域网 / 中继竞速，消息加密与解密
开发机远程服务
  ↓ 请求排队、会话索引、历史与实时事件、终端画面
助手适配与本地会话文件
  ↓ Claude / Codex / Cursor / Kimi / OpenCode / Pi
开发机上的真实会话

推送是旁路提醒：开发机远程服务 → 加密推送 → 手机通知扩展 → 用户点开后回到同一会话。
```

其中任何一层变慢，用户看到的都是“iOS 卡”；任何一层混淆身份，用户看到的都是“点进了另一台开发机”或“消息空白”。专项组按责任边界拆开，但验收按这条链路合并。

### 1.3 当前各层已有职责与主要风险

| 层 | 当前职责 | 本轮调查暴露的主要风险 |
|---|---|---|
| iOS 界面与交互 | 主机列表、会话列表、对话、终端、输入条、设置与空状态 | 页面局部已经有缓存优先、键盘避让和发送互斥，但全链路状态（首次加载、重连、空数据、失败恢复）还需逐屏统一验收 |
| iOS 连接与本地状态 | 局域网/中继选择、加密收发、请求与事件订阅、本地快照 | 收包、解密、解码和分发集中在同一条主执行链；控制请求、历史和终端高频画面共用一条设备通道 |
| 开发机远程服务 | 暴露手机所需的主机、会话、历史、实时事件与终端能力 | 大量历史读取、整表列表和心跳可能互相争用；列表与详情仍有“先生成完整结果再返回”的风险 |
| 助手适配与扫描 | 从六类助手的本地会话文件提取统一的会话、消息、状态和终端信息 | 文件规模、格式和更新时间各不相同；同一套索引或解析策略不能假设所有助手都一样 |
| 零知识中继 | 只转发密文帧，维护主机与设备的短时路由和限额 | 中继不能替代端到端恢复协议；换网后的路径选择、重连和缺口补齐必须由两端共同完成 |
| 推送与通知扩展 | 在手机未打开应用时提醒，并支持有限的快捷回复 | 权限、密文解包、通知点击回到正确会话和后台执行要单独验收，不能只看通知是否出现 |

## 2. 已知基线与需要重新测量的地方

以下数字来自 2026-08-29 的项目记录，作为问题规模的方向性基线，不作为本轮最终 SLO。第一波专项必须在同一台真实 iPhone、同一套开发机和可重复的 Wi-Fi/蜂窝/中继条件下重测，并保存原始样本。

- 历史会话数量约 535 条，历史文件总量约 34.7 GB。
- 在大列表样本中，整表返回约需 13.5 秒；约 87 MB 的单个大历史超过 20 秒仍未返回。
- 手机端收包、解密、解码仍主要在连接对象上完成后再交给界面；新客户端会再开一条数据连接承载历史页和终端画面，旧客户端仍单连接。
- 已有的正确方向不能被“优化”掉：本地快照先显示、版本不变不清空、事件合并、序号去重、终端空白格跳过绘制、发送前登记等待、局域网与中继竞速、重连时保留已有内容，以及禁止发送 `screen.resize`。
- **2026-08-30 已闭合（CLI 0.24.150 / iOS 1.0.11）**：JSONL 与 Cursor 第一次打开只读尾部；换网按序号补缺口；新手机控制/数据分两条连接。Kimi / OpenCode / Pi 仍走各自整段会话读取，不是这条尾部偏移路径。
- 仍未闭合：有限优先级背压、手机端后台解密/解码、连接路径与恢复过程的可观测性。真机换网与超大历史体感仍须在 the paired iPhone 上点一次确认。
- iOS 基线要求通知权限不要在应用刚出现时打断用户；当前启动流程仍需由专项确认合适的请求时机。

### 2.1 目前最值得先验证的瓶颈

这些是跨层责任链上的具体假设，必须由第 0 波的时间线和真实设备样本确认，不能直接当成“把某个数调小”或“换一种协议”来处理：

- **手机端主执行链过重**：收帧、解密、解压、解码、事件合并和界面状态提交集中在同一条主执行链，大帧或事件突发会直接表现为滚动、键盘和点击卡顿。
- **开发机服务的工作互相排队**：同一设备上的控制请求、心跳、历史读取和实时事件仍可能争用；JSONL/Cursor 冷缓存未命中时已改为只读尾部窗口，不要再把「整份读完再截最后一页」当成当前主因。Kimi / OpenCode / Pi 仍可能整段加载。
- **实时新鲜度有硬上限**：当前消息采集约每秒轮询一次、终端抓帧约每 200 毫秒一次；网络层再快，也不能越过这两个采集周期。应先验证文件/终端变化触发和自适应兜底的收益，再决定是否降低周期。
- **单连接队头阻塞**：新手机已把历史页和终端画面放到第二条连接；旧手机仍单连接。不要把「再拆第三条」或改回单连接当成列表首屏的修法。
- **中继慢消费者缺少显式治理**：转发写入、队列深度和等待时间还没有完整的有界策略与指标；手机变慢时，不能让内存或其他数据类型无限等待。

这几项决定了“毫秒级优化”应拆成多个可测的局部预算：手机交互反馈、端到端消息可见、控制请求排队、历史首屏、路径恢复和中继转发分别计时，不能用一个平均网络延迟代表全部体验。

权威上下文见：

- [手机客户端职责与验收入口](../../AGENTS.md)
- [手机客户端界面知识库](../UI_DESIGN_KNOWLEDGE_BASE.md)
- [手机客户端性能知识库](../PERFORMANCE_KNOWLEDGE_BASE.md)
- [移动端数据面设计](https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md)
- [远程接力知识库](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md)
- [中继协议 v2](../../../relay/docs/PROTOCOL_V2.md)

## 3. 建议成立的专项优化小组

建议成立 **7 个交付小组，外加 1 个横向质量与观测组**。前 7 组各自拥有可交付结果，横向组拥有统一的测量、真实设备验收和发布闸门；不要按“前端组/后端组”粗分，否则大历史、重连和中继问题会在边界处互相甩锅。

### 3.1 用户旅程与交互小组

**负责的用户结果**：用户从打开应用、选主机、选会话、查看历史、输入、等待助手、切到终端、换网、返回列表到收到推送，每一步都知道“现在发生了什么、下一步能做什么”。

**工作范围**：逐屏清点首次加载、已有缓存、刷新、空状态、失败、重连、停止、删除、搜索、键盘、终端和推送点击；统一加载与错误文案、状态保留、返回行为、发送反馈和可撤销操作。

**不负责**：不通过增加转圈时间掩盖数据面问题，不改远程协议，不把手机端猜测的助手状态当成事实。

**主要指标**：首屏可用时间、输入到本地反馈时间、发送重复率、重连期间内容保留率、错误后恢复成功率。

### 3.2 视觉、无障碍与本地化小组

**负责的用户结果**：在不同尺寸、浅色/深色、高对比度、动态字体、旁白和减少动态设置下，界面仍然清楚、可操作、没有系统蓝色焦点框或自绘助手标识混淆。

**工作范围**：设计令牌、层级与间距、系统容器、官方助手标识、状态颜色、动态字体、触控目标、VoiceOver 顺序、Reduce Motion/Transparency、中文与英文完整回退、图标和通知样式。

**不负责**：不另起一套“玻璃”内容层，不把设计效果图当成真实设备验收，不用固定颜色或固定文字覆盖服务端事实。

**主要指标**：真实设备逐屏截图、动态字体与辅助功能通过率、触控目标覆盖率、两种语言无键名/占位符、浅深色对比度。

### 3.3 手机运行时与渲染性能小组

**负责的用户结果**：收消息、解密、解码、更新列表/对话/终端不会阻塞主界面；输入跟手、滚动稳定、终端画面平滑，历史增大不会线性拖垮内存和电量。

**工作范围**：拆分主执行链与后台工作、限制状态更新范围、批量合并事件、控制终端绘制频率、避免重复布局与无效绘制、检查内存和电量、加入可关联的性能标记。

**不负责**：不以丢消息、丢历史或降低可见性换取“看起来更快”；不先改动画曲线或关闭系统功能。

**主要指标**：首屏/滚动/输入卡顿、消息接收至可见延迟、终端绘制丢帧、主执行链占用、峰值内存、异常退出率和电量消耗。

### 3.4 远程数据面与历史小组

**负责的用户结果**：打开列表和会话时先得到最有价值的内容；大历史不会阻塞实时消息；刷新、搜索和返回不会清掉正确的已有内容。

**工作范围**：本地快照与版本语义、增量索引、按尾部偏移/窗口读取历史、首屏摘要与详情分层、历史缓存淘汰边界、列表/详情/实时数据的优先级和容量上限。

**不负责**：不把整表慢简单改成滚动分页，不只扩大超时时间，不用压缩掩盖服务端仍在全量解析。

**主要指标**：有缓存和无缓存的首屏时间、列表/详情 p50/p95、首个新消息时间、大历史下实时消息延迟、传输字节数、缓存命中率和工作集大小。

### 3.5 协议与连接小组

**负责的用户结果**：连接选择可解释，换网能恢复，消息不重复不丢失，历史和实时不会互相饿死，协议升级可兼容旧客户端。

**工作范围**：控制与数据分通道、消息序号/代际/确认/补发、有限优先级背压、局域网与中继竞速和升级、断线恢复、压缩边界、版本协商和错误分类。

**不负责**：不在没有端到端指标时贸然更换 QUIC/自定义传输，不把中继当作可读取明文的服务器，不让手机自行猜测服务端状态。

**主要指标**：连接建立和握手耗时、路径切换成功率、恢复时间、重复/缺口率、每种数据的等待时间、重连期间控制请求成功率。

### 3.6 开发机服务与助手适配小组

**负责的用户结果**：手机看到的主机、会话、状态、消息和终端都来自正确的真实会话；服务忙时仍能及时处理控制请求。

**工作范围**：扫描和索引调度、六类助手的统一语义与差异适配、文件尾部读取、缓存失效、解析隔离、心跳与大任务隔离、会话身份校验、终端快照和实时事件生成。

**不负责**：不把某一助手的格式或固定黑名单硬编码成手机规则，不为了列表速度省略会话身份，不在共享中间件之外新建 JVM 服务。

**主要指标**：服务端 CPU/内存/锁等待、列表和详情生成耗时、不同助手的字段完整性、实时事件延迟、扫描失败率、同一会话身份一致率。

### 3.7 中继、安全与推送小组

**负责的用户结果**：用户在任意网络仍可安全接力；中继看不到正文；推送点开后回到正确会话；凭据和权限不会在异常路径泄露。

**工作范围**：配对与密钥生命周期、零知识转发、设备/主机路由、限额与滥用保护、局域网/中继状态展示、推送密文与通知扩展、快捷回复、权限请求时机、Keychain 与隐私审计。

**不负责**：不把调试信息写进推送，不把完整历史塞进通知，不用放宽加密或权限来换性能，不把一次配对扩大成不受控的远程入口。

**主要指标**：配对成功率、换网可达率、密文验证失败率、推送到达/点击回会话成功率、密钥轮换和撤销、异常访问拦截率。

### 3.8 横向质量、观测与发布小组

**负责的用户结果**：每个优化都能在真实 iPhone 和真实网络上证明，发布后能知道是哪一段变慢或丢失，而不是以“编译成功”收工。

**工作范围**：统一事件时间线和性能标记、MetricKit/Instruments 采集、合成大历史样本、六助手矩阵、Wi-Fi/蜂窝/中继/断网/恢复测试、截图与辅助功能验收、版本与签名核对、回归门禁和故障复盘。

**不负责**：不最后一天才测试，不用单元测试、模拟器或单条会话代替端到端证据，不为了让仪表盘好看删除失败样本。

**主要指标**：端到端 p50/p95、真实设备覆盖率、版本兼容矩阵、缺口/重复检测、崩溃与卡顿率、每次发布的可追溯性。

## 4. 依赖关系与启动顺序

### 第 0 波：先建立共同事实（所有优化的入口）

横向质量与观测小组先建立一条可复现的“用户动作时间线”，至少记录：点击时间、路径选择、连接建立、服务端收到请求、历史/事件生成、手机收到、解密/解码完成、界面可见、用户可再次操作。样本覆盖：冷启动/热启动、无缓存/有缓存、普通会话/大历史、六类助手、局域网/蜂窝/中继、切网和断线恢复。

这一波只测量和补观测，不用局部优化数字冒充全链路改善。Apple 对 SwiftUI 卡顿建议使用 Instruments，MetricKit 适合收集真实设备上的启动、响应、网络、CPU、内存和诊断数据，连接建立与数据传输也应记录路径级报告。

### 第 1 波：两条可以并行的设计线

- 用户旅程与交互、视觉无障碍小组：完成逐屏状态矩阵和真实设备截图清单。
- 数据面、协议连接、开发机服务、手机运行时四组：基于同一时间线，确定控制/历史/实时/终端的优先级、序号恢复和后台处理边界。
- 中继安全与推送小组：对所有协议改动做密文、配对、权限和推送兼容审查。

### 第 2 波：按一条可验收闭环交付

先交付“打开主机 → 显示缓存列表 → 后台刷新 → 打开一个普通会话 → 接收一条新消息 → 发送一条输入 → 短暂断网 → 自动恢复”的最小闭环；再加入大历史、终端画面、切网、推送和六助手差异。每个闭环都由横向组在真实手机上验收后才进入下一闭环。

### 第 3 波：发布与回归

通过完整设备矩阵、浅色/深色、动态字体、旁白、英文/中文、权限首次出现和升级安装验证后，才做正式版本。协议和服务端改动必须同时验证旧版手机仍能得到明确的兼容提示，不允许只看最新版本。

## 5. 第一版共同指标（先测量，再锁定数值）

下表是建议的首轮预算，实际数值须用第 0 波的同机同网基线校准；它们是用户体验预算，不是要求互联网 RTT 变成毫秒级。

| 用户动作 | 建议首轮预算 | 必须证明的结果 |
|---|---:|---|
| 再次打开已访问主机 | 本地已有内容约 300 ms 内可见 | 不等网络；刷新在后台进行；失败保留旧内容 |
| 无缓存打开列表 | 局域网 p95 约 2 s；中继 p95 约 8 s | 先显示可用摘要；数据规模增大不能线性卡死界面 |
| 打开普通会话 | 已缓存正文约 300 ms 内可见；新内容按局域网/中继分别统计 | 历史读取不阻塞实时事件；返回列表不丢状态 |
| 点击发送 | 100 ms 内看到本地发送反馈 | 连点不重复；失败可恢复原输入；服务端确认单独计时 |
| 新消息到可见 | p95 先以 100 ms 级别为目标 | 不因批处理造成明显空窗；不重复、不静默丢失 |
| 切网或短暂断线 | 约 5 s 级别恢复，具体以路径条件校准 | 页面保留上下文；恢复后按序补齐；用户能看到当前路径和下一步 |
| 大历史与终端并行 | 工作集有上限，不能随历史文件线性增长 | 控制输入、实时消息和终端画面仍有可用带宽 |

## 6. 不能作为“优化完成”的替代方案

这些做法不能单独关闭问题：

- 只把等待时间或重试次数调大。
- 只做压缩，却仍在服务端一次性读取和解析完整历史。
- 把列表改成滚动分页，就宣称首屏已解决。
- 把“版本没变化”误当作“没有数据”，或把失败响应覆盖成本地缓存。
- 在手机端内置助手名称、颜色、状态或某个助手的固定过滤规则。
- 为了画面稳定发送 `screen.resize`，改变开发机真实终端的共享尺寸。
- 只看编译、单元测试、模拟器、单条会话或一次局域网请求，不做真实 iPhone 的整链路验收。
- 在没有数据和安全基线前更换传输技术或扩大中继权限。

## 7. 每个小组的完成定义

一个专项只有同时满足以下条件才算完成：

1. 有明确的用户动作和端到端指标，能指出改善发生在哪一段。
2. 在真实 iPhone 上验证，至少覆盖有缓存/无缓存、局域网/中继和一次切网或断线恢复；涉及助手时覆盖六类助手。
3. 有失败、超时、重复、缺口、权限拒绝和旧版本兼容证据，而不只展示成功路径。
4. 没有破坏既定边界：本地优先、服务端事实、端到端加密、禁止 `screen.resize`、完整中英文和系统无障碍。
5. 观测数据、截图、版本号和复现步骤能被下一位维护者重新得到，并写回对应知识库。

## 8. 参考依据

### 项目内权威文档

- [iOS 项目入口与真机验收](../../AGENTS.md)
- [UI 设计知识库](../UI_DESIGN_KNOWLEDGE_BASE.md)
- [性能知识库](../PERFORMANCE_KNOWLEDGE_BASE.md)
- [移动端数据面设计](https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md)
- [远程接力知识库](https://github.com/corral-dev/corral/blob/main/docs/REMOTE_KNOWLEDGE_BASE.md)
- [中继协议 v2](../../../relay/docs/PROTOCOL_V2.md)

### 官方与同类实现

- Apple：[Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)、[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)、[Loading](https://developer.apple.com/design/human-interface-guidelines/loading)、[SwiftUI performance analysis](https://developer.apple.com/documentation/swiftui/performance-analysis)、[MetricKit](https://developer.apple.com/documentation/metrickit)、[NWConnection data transfer reports](https://developer.apple.com/documentation/network/nwconnection/datatransferreport)。
- [Shellular](https://github.com/shellular-org/shellular)：手机访问既有开发环境，主机与手机端到端加密，中继只承担转发；其应用、主机服务、协议和服务器边界值得参考。
- [Spectty](https://github.com/ocnc/spectty)：原生 iOS 终端、会话持久化、自动恢复和 GPU 终端渲染，说明连接生命周期与终端绘制应分开治理。
- [Shelly](https://github.com/iamjr15/shelly)：通过序号、追赶、有限缓存和滞后状态处理断线恢复，说明协议必须为缺口检测和恢复预留语义；其 iOS 客户端当前不是本项目可直接复用的成品。
- [Mosh](https://github.com/mobile-shell/mosh)：状态确认、按确认状态重算差分、有界队列和 RTT 自适应值得借鉴；其自研 UDP、终端预测和协议不能直接替换 Corral 的加密 WebSocket、中继和推送边界。

## 当前建议

先启动横向质量与观测、用户旅程与交互、协议与连接三条线；它们分别回答“到底慢在哪里”“用户到底卡在哪一步”“数据怎样不丢不重”。随后让手机运行时、远程数据面、开发机服务、中继安全四组按同一协议草案并行实施，视觉无障碍小组贯穿每个可见页面。这样既能尽快改善用户感知，也不会把 UI 重绘、网络调参和服务端重构做成互相独立的项目。

<!-- 该文档整理/压缩于 2026-09-05 -->

## Connection and notification identity corrections (2026-09-30)

Requirements recorded before implementation:

- A receive, heartbeat, probe, upgrade, hello, or data-binding result may affect only the exact physical control/data connection that started it. Replacing or disconnecting that connection invalidates its callbacks; an obsolete winner must close its own socket. Task cancellation alone does not establish this boundary: [Swift's structured concurrency specification](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md) describes cooperative cancellation and suspension points.
- Notification quick replies must resolve the paired host identified by the notification, connect to that host when needed, and recheck the ready connection's host before sending. A reply without a known paired host must not use the currently selected machine. Each reply uses a fresh command receipt ID when the host supports receipts; ambiguous sends are not automatically retried. Notification actions are dispatched through the [notification response delegate](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions).

Confirmed review symptoms: cancelled old sockets could report a receive/heartbeat error after a replacement became ready and tear down the replacement; delayed data-binding results could attach to a newer control connection. A quick reply to host B while the app was connected to host A reused A's client, exposing the reply to the wrong host, and omitted the receipt ID on receipt-enabled connections.

Verification remains separate: regression tests cover stale physical-connection callbacks and reply destination selection; real iPhone reconnect, cross-host quick reply, and APNs delivery still require device-path evidence. Normal notification taps open their session through the tap navigation below.

## Notification-tap navigation

- A normal body tap (`UNNotificationDefaultActionIdentifier`, plain
  `UNNotificationResponse` with empty text) opens the paired host from
  `userInfo["host_id"]` and then its `userInfo["session_key"]` session, using only
  the existing path `NavigationStack → HostInfo → SessionListView → SessionRoute →
  SessionDetailView`. No new route types, no new product entries, no terminal
  surface (`ProductFeatures.terminalPaneEnabled` stays off).
- Tap dispatch branches on `response.actionIdentifier`: `REPLY` with non-empty text
  uses the established `NotificationReply.send` path (send-only, no navigation
  change); default-action taps navigate and never emit `input.text`;
  dismiss/unknown identifiers stay no-ops. `completionHandler` fires exactly once
  via the existing `defer`, never held for network.
- Host ownership for taps mirrors the reply correction: resolve by `host_id`, never
  the current selection; unpaired or removed hosts are ignored without navigation.
- The pending open request is single-value and idempotent: a ticket bumps only on
  actual change, so rapid identical taps collapse while a later tap after
  consumption routes again. Each new ticket replaces the navigation path with the
  tapped host; repeats of the routed ticket are no-ops.
- The host leg navigates on paired identity immediately, never waiting for a live
  connection. The session leg reads the persisted per-host snapshot and tail cache
  first and is consumed only by the visible list: known keys push from cache or
  snapshot; unknown keys never push a fallback route because list windows
  (`has_more`) are not an authoritative catalog. An unknown key is resolved with a
  direct `session.get` lookup once the host is connected — merged into the store
  (tapped key kept as an alias when the server returns a canonical key) and then
  opened exactly. Only the server's explicit `not_found` consumes the ticket, with
  a visible dismissible recovery; transport failures keep the ticket retryable, one
  lookup per ticket, superseded or wrong-host results dropped. Opening is a read;
  no synthesized messages.
- Cold-launch retention: the notification-center delegate is assigned before the app
  finishes launching, so a tap can arrive before the model attaches. The request is
  stored unconditionally; paired-host validation and the connection kick are deferred
  until `configure()` replays them, and the root explicitly routes on appear, so a
  pre-appearance tap cannot be lost. Unpaired hosts stay stored-but-harmless.
- Same-root ownership in `SessionListView` refresh/watch: capture the exact client,
  verify it still serves this host before applying snapshots, starting watchers, or
  handling ready callbacks; a monotonic refresh revision keeps stale responses and
  failures from touching newer loading state or errors; teardown unregisters and
  un-watches on the client the view attached to.
- Unit-regression boundary (macOS `swift test` portable): the tap-branch decision,
  the pending-request store, the new-ticket routing rule, the direct-lookup
  resolution policy (window misses wait, only explicit `not_found` ends the tap,
  one lookup per ticket), the cold-launch routability rule, and the list
  placeholder policy are pure Foundation logic covered without UIKit, simulator,
  or APNs. Device-path evidence
  (cold-launch tap, background tap, cross-host reply, reconnect races) remains
  coordinator-run on the paired iPhone.

## Review verification (2026-09-30)

- The integrated workspace passes 187 portable XCTest regressions, including
  stale socket callbacks, cross-host replies, cache/generation isolation,
  suspended tool details, draft recovery, partial attachment recovery, and
  provisioning-environment parsing. Localization validation passes all 186 key
  usages. These results exercise product logic; they do not prove APNs delivery
  or navigation on the phone.
- Xcode 27.0 builds the complete Release app and notification extension for
  `generic/platform=iOS`, and the complete Debug hosted unit-test target via
  `build-for-testing`. Both bundles report 1.0.71 (81), with valid signatures.
  The Release app's actual `aps-environment` is `development`, so its token must
  be registered as sandbox even though the build configuration is Release.
- At validation time the paired iPhone is unavailable; the paired iPad requires a
  passcode. Cross-host switching, notification taps/replies, offline navigation,
  question interaction, and partial image failure still need physical-device
  evidence. Direct installation and AppShelf publication have separate outcomes.
- General asynchronous ownership and signing lessons are maintained in the
  [shared Swift client integration guide](../../../../_standards/workspace-docs/swift-docs/client-backend-integration.md).

Delivery evidence: commit `890fc83` is pushed to `main`; the published
v1.0.71 release
points to that exact commit. The signed IPA is published at
the internal install shelf, with a server receipt matching bundle
`com.x0c.corral`, version 1.0.71, build 81 (release 123). Direct the paired iPhone
installation returned `device_unavailable`; no installed-version readback,
launch, screenshot, or phone interaction was obtained. Hosted tests on the
paired iPad stopped at "Unlock iPad to Continue" before test execution; no
simulator or second test-driver app was used. The production profile reader was
also run against the actual signed app bundle and returned `sandbox`, matching
its signed `development` entitlement.

## Client diagnostics and Agent workflow (2026-10-05)

The iPhone and native Mac clients must expose a privacy-safe, bounded operational record for connection races, control/data-plane failures and recovery. Diagnostics record only fixed event names, client-run identifiers, transport/state, counts, numeric error codes and monotonic durations; never conversation text, request/response bodies, session/host identifiers, network addresses, pairing codes or keys. Apple unified logging is the system inspection route ([Apple logging](https://developer.apple.com/documentation/os/logging/)); a bounded JSON report supports deterministic Agent reads without UI automation.

Reports are isolated by process and client instance, written atomically off the main actor at no more than one periodic snapshot per second, and retained within a bounded file count. A report includes version, timestamp and process identity so stopped or stale clients cannot be mistaken for current health. Diagnostics failure must never prevent connection or recovery. Test processes use an in-memory recorder unless given an explicit temporary destination.

The repository diagnostic entry must be read-only, non-interactive, dependency-free, offer compact JSON success/failure envelopes and meaningful exit codes, and expose status, bounded events and prerequisite checks. It must distinguish stale records, missing evidence and actual live connection state, and never reconnect, send a message or modify pairing as a side effect. Scope: Corral development/diagnosis; general machine-wide configuration is not implied.

### Agent diagnostic entry

From `apple/`, run `python3 scripts/client_diag.py doctor`, then `status`. The dependency-free source script is the pinned entry; no install or credentials are required. Non-TTY output is `{ok,data,error,meta}` JSON; `--json` also forces it. `describe` works offline. `events --run <clientRun> --limit 30` reads one exact run returned by `status`. `verify` requires fresh local process evidence, ready control and attached data; it refuses partial/malformed evidence. It does not certify conversation rendering or message delivery. Exit codes: 0 success, 1 failed verification/read, 2 invalid arguments, 3 absent report/run.

Reports live in `AppStorageLocation.appDirectory/diagnostics/` (`~/.config/corral-mac/diagnostics/`, respecting `XDG_CONFIG_HOME`, on Mac; the existing Corral Application Support directory on iOS). Each process/client has its own file; retain at most 16 files and 128 timeline entries per run. Successful responses increment counters rather than flooding the timeline. A five-second heartbeat updates idle clients; freshness is 20 seconds. A stopped process, suspended phone, missing report or unreadable report is never evidence of current health. To inspect iPhone reports, copy the existing app container with `devicectl device copy from --domain-type appDataContainer --domain-identifier com.x0c.corral --source Library/Application\ Support/Corral/diagnostics --destination <temporary-directory>` using the paired device selector, then pass `--directory` to the same reader. Phone PIDs are not checked on the Mac; verify device/version and host-online state separately.

Validation commands: `python3 scripts/test_client_diag.py` (isolated contract checks), `swift test` (portable core), `python3 scripts/check_localizations.py`, `python3 scripts/test_mac_lifecycle.py`, then signed generic iOS and Mac Xcode builds. Run the installed client and read `status`/`events`/`verify`; unit tests alone do not establish active-client behavior. Existing build and `ios-deliver` remain the delivery authorities; diagnostics never reimplements signing, installation or upload. No automatic send/restart/pairing is part of this entry.

Operational request timing is measured with `ContinuousClock`: pending-registration to terminal removal (response, timeout, send failure or teardown). `completedWaits`, `maxWaitMs` and `slowWaits` describe waits, not successful delivery. Waits of at least one second add a bounded `slowRequest` event; rejected replies, malformed/orphan responses and receive/ping/idle failures are distinct evidence. Normal race cancellation is separate from a failed connection.

### Verified diagnostics and parallel-development obstacle

Source `8eb803f`: 300 portable tests, four isolated diagnostic CLI contract tests, localization coverage and Mac lifecycle checks passed. Signed generic iPhone and universal Mac Release builds were made from an exported commit. iPhone 1.0.106 (116) was directly installed/launched with version readback and uploaded independently to AppShelf (release 200). Mac 0.3.5 (9) was signature-verified and installed; its real process wrote fresh reports, response counters, request waits and connection transitions. Phone reports were read from the actual app container with the same reader; their PIDs correctly remain unverified on the Mac.

Real-path evidence: the installed Mac window displayed the live session list while its connection was reconnecting. Timelines showed successful control races and data attaches followed by receive failures (numeric code 57), retry scheduling and subsequent races. Multiple Debug clients using the same pairing were running concurrently. This is verified diagnostic collection and conservative failed-health verification, **not** proof of stable connectivity, message delivery or physical interaction. The older stopped client reports were marked stale/dead.

Environment improvement: coordinate or isolate parallel Debug client identities so simultaneous acceptance runs cannot supersede one another's sockets. Keep the installed Release identity stable, never erase pairing to make a test pass, and do not drive another task's UI. Until isolation is verified on both client and host, inspect all process/run records and report the interference explicitly. This obstacle requires a supported development mechanism rather than another timeout tweak.

Diagnostic health requires a successfully acknowledged data-plane hello. Creating its socket or assigning `dataPlane` is only an attachment in progress and must not make diagnostic `dataAttached` true. Teardown/replacement invalidates this confirmation; regular client attachment behavior stays unchanged.

Integration gate: source `90e2b31` passed 310 portable core tests but its iOS Xcode build rejected the shared `sessionMarker` call. `ChatView` has an explicit initializer: declaring the stored property is insufficient; it must accept and assign the same marker already forwarded by `SessionDetailView`. Source `2a77b85` supplies the missing initializer parameter/assignment. Portable tests exclude SwiftUI and cannot certify this wiring; keep the signed generic iOS build as a required gate.

For compact Agent preflight, `status --active` filters to fresh reports whose local process is alive. It returns the same client fields and full read coverage plus matched/returned/omitted counts; no match is not a healthy connection. The unfiltered status remains available for stopped runs and copied phone evidence. This is additive to the schema-1 contract.

Retained older schema-1 reports predate confirmed data health. `verify` must require the confirmed-data contract introduced in Mac 0.3.8 / iPhone 1.0.108; older reports remain readable, but their attachment-only flag cannot certify readiness. `confirmsDataHello` labels this distinction.

Hosted UI unit tests must share the actor isolation of the production UI they exercise. The full `build-for-testing` gate caught a synchronous nonisolated call in `ChatActivityStateTests` that portable Core coverage excludes; mark this UI test class `@MainActor`, consistent with the [Swift compiler guidance](https://docs.swift.org/compiler/documentation/diagnostics/actor-isolated-call/), and rebuild the hosted target. This is test wiring, not a product behavior change.

### Delivery and remaining acceptance limits

The integrated source `94c10dc` passes the complete generic-iOS hosted `build-for-testing` target after the UI-test isolation correction. Portable Core coverage passed 310 tests; the diagnostic reader passes five isolated contract tests; localization covers 352 usages. Signed generic iOS and universal Mac Release artifacts exported from `20333a24` passed their builds and signatures; both release assets have matching server size receipts (iPhone 1.0.108, Mac 0.3.8).

The installed Mac was subsequently advanced by parallel work to 0.3.9 (13), which includes the diagnostics. Its actual installed process passed the reader's confirmed-data health check: ready local control, acknowledged data, zero pending waits and zero scheduled retries. A later absent/newly replaced process correctly failed verification. This establishes real diagnostic behavior, not sustained connectivity under concurrent Debug clients. The earlier installed Mac window was inspected; final-window captures failed while parallel acceptance replaced/closed windows, so no new visual proof is claimed.

iPhone app inventory independently confirms installed 1.0.108 (118), and AppShelf independently confirms release 202 at . The device requires its passcode: latest launch/runtime and screen acceptance remain unverified. Existing physical-device reports from 1.0.106/107 were copied and parsed, with stale evidence rejected and phone PIDs deliberately unverified on the Mac. No simulator was used.

An independent fresh-Agent usability evaluation was not run: the current task does not authorize worker delegation. Primary-model contract checks and real-client reads were performed instead; do not label these as an independent usability evaluation. The remaining development obstacle is concurrent Debug pairing/socket interference, tracked above; this bounded diagnostic delivery does not claim that all development friction has been eliminated.


## Creation and input outcome reliability (2026-10-09)

Owner-approved shared iPhone/Mac correction: retain a durable creation identity before calling the host and reuse it after a transport failure; reconcile the same request instead of launching another empty session. Poll accepted/dispatching text receipts until the host establishes native acceptance or a useful uncertain/failure outcome. Cancel provisional Working on failure/uncertainty and retain the original outgoing instruction for review. Existing native New Session `Button`, `ProgressView` and error text remain the interface; no extra confirmation step is introduced. Host semantics and acceptance matrix are owned by [the mobile data plane design](https://github.com/corral-dev/corral/blob/main/docs/design/MOBILE_REMOTE_DATA_PLANE_DESIGN.md#10-creation-and-first-input-reliability-2026-10-09).

The Mac workspace assistant shortcut must use the same creation coordinator as New Session. A host/client switch while creation awaits must not open the result in another machine’s workspace; the original durable operation remains recoverable.


Validation: 362 portable Core tests pass, including a real ConversationStore polling task resolving accepted to reviewable unknown while its connection remains open. Core compilation has no new warnings; native lifecycle/selection probes and localization coverage pass. Fresh generic-device iOS and native Mac Release builds include these changes. The existing native font/paragraph, serial camera queue, terminal trait and App Intents warnings retain the individual origin/risk/follow-up assessments in [New Session diagnostic review](../PERFORMANCE_KNOWLEDGE_BASE.md#new-session-delivery-diagnostic-review); no warning suppression was introduced. The Mac is locked during SSH work, so physical window and phone gesture/error presentation remain unverified. Build/logic checks are not physical acceptance.

Delivery: shared source `6965329` is pushed/tagged as iPhone 1.0.138 (148) and Mac 0.3.60 (64). AppShelf release 227 holds the signature/profile-verified iPhone artifact at the internal install page; paired-device installation/launch failed independently with `device_unavailable`. Mac 0.3.60 is installed from the signed universal export and the actual process is ready over local control with data attached after the CLI 0.24.276 host restart. This proves installation/connectivity, not physical New Session or receipt-error interaction. Distribution follow-up is tracked in [Mac distribution](MACOS_CLIENT_DESIGN.md#distribution-and-software-updates).
