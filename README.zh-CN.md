**语言：** [English](README.md) | 简体中文

<p align="center"><img src="docs/images/corral-icon.png" alt="Corral" width="112" height="112"></p>

# Corral iPhone 与 Mac 客户端

通过原生 Apple 客户端跟进编程助手。在 Corral 开发机上的助手继续运行时，阅读对话、回答问题。Mac 上可让每个显示区域在聊天与助手终端之间切换。

- 为 iPhone 和 Mac 构建的原生 SwiftUI 客户端。
- 在同一个会话列表中查看 Claude Code、Codex、OpenCode、Cursor 和 Pi。
- 键盘快捷键、项目筛选和对话全文搜索。
- Mac 上最多四个会话并排显示。
- Mac 上可切换聊天与助手终端；两端都支持开发机上的项目终端。

这是开源测试版，目前尚无公开的 App Store 或 TestFlight 下载。Mac 客户端需要 macOS 26 或更新版本；iPhone 客户端需要 iOS 17 或更新版本。

## 安装

macOS：先安装 Xcode 及其命令行工具，再构建并安装客户端：

```bash
curl -fsSL https://raw.githubusercontent.com/corral-dev/corral-apple/main/install.sh | bash
```

安装器使用你本机自行构建的应用，不包含维护者的签名身份、更新服务或托管中继。默认安装到 `~/Applications`；可通过 `CORRAL_APP_DIR` 指定其他应用目录。

iPhone：克隆本仓库，使用 Xcode、你自己的开发者团队和唯一的应用标识构建。推送通知能力需要付费 Apple Developer 账号。构建、安装和本地签名设置见[公开构建指南](docs/PUBLIC_BUILD_GUIDE.md)。

## 连接开发机

在运行编程助手的机器上安装 [Corral 终端应用](https://github.com/corral-dev/corral)及其远程功能依赖，然后运行：

```bash
corral remote pair
```

在同一局域网中从客户端配对。配对会授权客户端读取和操作开发机上的会话，请保密一次性配对码。助手仍在开发机上运行，因此开发机需要保持唤醒且可连接。

跨网络连接时，自行部署 [Corral 中继](https://github.com/corral-dev/corral-relay)，并在开发机配置其 `wss://` 地址。开源客户端不内置共享公共中继。APNs 推送通知还需要自建中继上的应用标识和推送密钥与客户端匹配。

## 隐私

会话通信和推送正文在开发机与客户端之间加密。中继仍能看到连接时间、路由标识和字节数。设备密钥保存在 Keychain 中。客户端可能缓存对话，以便重新打开历史；详见[隐私说明](PRIVACY.md)。

请勿在公开问题中提交配对码、密钥、私人对话或机器地址。涉及安全的发现请使用[私密安全报告](https://github.com/corral-dev/corral-apple/security/advisories/new)。

## 开发

iPhone 外壳位于 `iOS/`，Mac 外壳位于 `macOS/`，共享客户端代码位于 `Shared/`，推送扩展位于 `NotificationService/`。`Package.swift` 用于验证可移植的客户端逻辑；应用通过 XcodeGen 和 Xcode 构建。

```bash
swift test
python3 scripts/check_localizations.py
```

提交改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。外部贡献需要接受[贡献者协议](CLA.md)。

## 许可

软件采用 [GPL-3.0-only](LICENSE)。Corral 名称和花朵牛仔帽图案遵循独立的[品牌政策](BRAND_POLICY.md)。依赖和各助手提供商的标识保留各自的许可与归属，见[第三方声明](THIRD_PARTY_NOTICES.md)。
