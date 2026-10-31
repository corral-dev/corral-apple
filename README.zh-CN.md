**语言：** [English](README.md) | 简体中文

<p align="center"><img src="docs/images/corral-icon.png" alt="Corral" width="112" height="112"></p>
<h1 align="center">Corral iPhone 与 Mac 客户端</h1>
<p align="center"><strong>随时跟进编程助手，让任务继续往前走。</strong></p>

通过原生 Apple 客户端阅读回复、回答问题，并向 Claude Code、Codex、OpenCode、Cursor 或 Pi 发送下一条指令。助手运行在 macOS 或 Linux 上的 [Corral 开发机](https://github.com/corral-dev/corral)。

- **看到谁在等你。** 在同一个会话列表中跟进五种助手。
- **同时处理多个会话。** Mac 上最多四个区域并排显示。
- **选择查看方式。** 每个 Mac 显示区域都可切换聊天与助手终端。
- **找到正在做的事。** 按项目筛选，搜索对话全文。
- **随手回复。** 在 Mac 上用键盘快捷键操作，或从 iPhone 回复。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/mac-split-dark.png">
    <img src="docs/screenshots/mac-split-light.png" alt="Corral Mac 版：左侧为会话列表，右侧并排显示一个 Claude Code 会话和一个 Codex 评审会话" width="100%">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/iphone-sessions-dark.png">
    <img src="docs/screenshots/iphone-sessions-light.png" alt="Corral iPhone 版会话列表（演示数据）" width="45%">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/iphone-chat-dark.png">
    <img src="docs/screenshots/iphone-chat-light.png" alt="Corral iPhone 版代码评审对话（含工具调用）" width="45%">
  </picture>
</p>

## 安装

**Mac 版**提供签名安装包，直接下载即可。**iPhone 版**目前是源码测试版，需要使用 Xcode 构建。尚无公开的 App Store 或 TestFlight 下载。

| 客户端 | 要求 |
| --- | --- |
| Mac | macOS 26+（从源码构建还需要带有 macOS 26 SDK 的 Xcode） |
| iPhone | iOS 17+、Xcode、自己的签名团队及一台实体 iPhone |
| 开发机 | 在 macOS 或 Linux 上安装 [Corral CLI](https://github.com/corral-dev/corral#install)和编程助手 |

### Mac

通过 Homebrew 安装已签名的 Mac 客户端：

```bash
brew install --cask x0c/tap/corral-mac
```

已经安装官方 DMG？先登记到 Homebrew：

```bash
brew install --cask --adopt x0c/tap/corral-mac
```

从「应用程序」打开 Corral。登记后，用以下命令更新：

```bash
brew update
brew upgrade --cask x0c/tap/corral-mac
```

内置更新仍然可用。当前 Homebrew 能识别比安装记录更新的应用，因此登记版本较旧不代表更新失败。安装时报“already an App”表示目标位置已有应用，请根据情况使用上面的接管或更新命令。不要把 `--force` 当作常规修复：它可能用 tap 的旧版本覆盖较新的应用。配对和设置会保留。详见 [Homebrew 对应用内更新的处理](https://docs.brew.sh/FAQ#how-does-brew-upgrade-handle-apps-that-update-themselves)。

下载[已签名的 Mac DMG](https://github.com/corral-dev/corral-apple/releases/latest)，把 Corral 拖进「应用程序」。之后每小时检查一次更新，后台下载，并在退出时安装。

如果想从源码构建，安装好 Xcode 及其命令行工具后运行：

```bash
curl -fsSL https://raw.githubusercontent.com/corral-dev/corral-apple/main/install.sh | bash
```

从 `~/Applications` 打开 Corral。若要选择其他安装目录，运行安装器时设置 `CORRAL_APP_DIR`。

### iPhone

先安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)，再克隆源码并生成 Xcode 项目：

```bash
git clone https://github.com/corral-dev/corral-apple.git
cd corral-apple
xcodegen generate
```

打开 `Corral.xcodeproj`，选择自己的团队和唯一的应用标识，在 iPhone 上构建运行。共享 Keychain 分组与通知扩展的设置见[构建与签名指南](docs/PUBLIC_BUILD_GUIDE.md)。推送通知需要 Apple Developer 会员资格。

## 与开发机配对

在运行助手的机器上执行：

```bash
brew install x0c/tap/corral
corral remote pair
```

若已安装 Corral，只需执行第二条命令。也可选择[其他 CLI 安装方式](https://github.com/corral-dev/corral#install)。

在同一局域网中打开 Apple 客户端，扫描或粘贴配对码。配对会授权客户端读取和操作开发机上的会话；若只需查看，可使用 `corral remote pair --readonly`。请保密配对码。开发机必须保持唤醒，助手与远程访问才能继续工作。

## 从其他网络访问

自行部署 [Corral 中继](https://github.com/corral-dev/corral-relay#quick-start)，并在开发机配置其 `wss://` 地址。同一网络内可以直连。开源客户端使用你配置的中继，不包含共享托管中继。

若需要 iPhone 通知，在中继上配置与自己的应用标识匹配的 APNs 凭据。未配置 APNs 时，客户端打开期间仍能实时更新对话。

## 隐私

会话通信和推送正文采用端到端加密。中继可看到路由标识、连接时间和字节数。设备密钥保存在 Keychain 中；客户端可缓存对话，以便重新打开历史。详见 [PRIVACY.md](PRIVACY.md)。

## 获取帮助与参与贡献

- [构建与签名指南](docs/PUBLIC_BUILD_GUIDE.md)
- [报告问题或提出功能建议](https://github.com/corral-dev/corral-apple/issues/new/choose)
- [参与贡献](CONTRIBUTING.md)与[贡献者协议](CLA.md)

公开报告前请去除私人对话、机器地址和配对凭据。漏洞请使用[私密安全报告](https://github.com/corral-dev/corral-apple/security/advisories/new)。

## 🧩 AI 编程工具链里的相关工具

如果你每天在多个 AI 编程助手之间切换，看看这套本地优先工具链的其余部分：

| 仓库 | 说明 |
| :--- | :--- |
| **[corral](https://github.com/corral-dev/corral)** | 在终端会话管理器里并排跑 Claude Code、Codex、OpenCode、Cursor 和 Pi，再从 iPhone 或 Mac 上继续。 |
| **[subswap](https://github.com/x0c/subswap)** | 查剩余额度，一键切换 Claude Code、Codex、Cursor、Kimi Code 和 OpenCode 的账号，不用反复登录。 |
| **[agentsync](https://github.com/x0c/agentsync)** | 以一份本地源统一同步 `AGENTS.md`、`CLAUDE.md`、skills 和 MCP 配置到各编程助手。 |
| **[agent-doc-skills](https://github.com/x0c/agent-doc-skills)** | 可导航的项目知识库 skills（`doc-init`、`doc-update`、`doc-compact`），让 coding agent 不再每个会话都重新认识你的仓库。 |

## 许可

[GPL-3.0-only](LICENSE)。Corral 名称与花朵牛仔帽图案遵循独立的[品牌政策](BRAND_POLICY.md)。依赖及各助手提供商的标识保留各自的许可与归属，见[第三方声明](THIRD_PARTY_NOTICES.md)。
