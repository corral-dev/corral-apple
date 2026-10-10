**Languages:** English | [简体中文](README.zh-CN.md)

<p align="center"><img src="docs/images/corral-icon.png" alt="Corral" width="112" height="112"></p>

# Corral for iPhone and Mac

Follow your coding agents from a native Apple client. Read conversations and answer questions while the agents keep running on your Corral host. On Mac, switch each pane between chat and the agent's terminal.

- Native SwiftUI clients for iPhone and Mac.
- Claude Code, Codex, OpenCode, Cursor and Pi in one session list.
- Keyboard shortcuts, project filters and full-text conversation search.
- Up to four sessions side by side on Mac.
- Chat and agent-terminal views on Mac; host-side project terminals on both clients.

This is an open-source beta. Public App Store and TestFlight downloads are not available yet. The Mac client requires macOS 26 or later; the iPhone client requires iOS 17 or later.

## Install

For macOS, install Xcode and its command-line tools, then build and install the client:

```bash
curl -fsSL https://raw.githubusercontent.com/corral-dev/corral-apple/main/install.sh | bash
```

The installer uses your own local build. It does not include the maintainer's signing identity, update service or hosted relay. It installs into `~/Applications` by default; set `CORRAL_APP_DIR` to choose another application directory.

For iPhone, clone this repository and use Xcode with your own development team and unique bundle identifiers. A paid Apple Developer account is required for the push-notification capability. Build/install instructions and required local signing settings are in [the public build guide](docs/PUBLIC_BUILD_GUIDE.md).

## Connect your host

Install the [Corral terminal app](https://github.com/corral-dev/corral) and its remote dependencies on the machine that runs your agents. On that host:

```bash
corral remote pair
```

Pair from the client on the same local network. Pairing grants the client access to read and act on your host's sessions; keep the one-time pairing code private. Agents continue running on the host, so it must remain awake and reachable.

To connect from another network, run your own [Corral relay](https://github.com/corral-dev/corral-relay) and configure its `wss://` address on the host. Open-source clients do not bundle a shared public relay. APNs notifications additionally require a matching app identity and push key on your self-hosted relay.

## Privacy

Session traffic and notification text are encrypted between the host and client. A relay still sees connection timing, routing identities and byte counts. Device keys are held in Keychain. Conversations may be cached on the client to support reopening history; see [the privacy notice](PRIVACY.md).

Do not include pairing codes, keys, private conversations or machine addresses in public issues. Use [private security reporting](https://github.com/corral-dev/corral-apple/security/advisories/new) for security-sensitive findings.

## Development

The iPhone shell is in `iOS/`, the Mac shell in `macOS/`, shared client code in `Shared/`, and the push extension in `NotificationService/`. `Package.swift` exercises portable client logic; the applications build through XcodeGen and Xcode.

```bash
swift test
python3 scripts/check_localizations.py
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting changes. Contributions require the [contributor agreement](CLA.md).

## License

Software: [GPL-3.0-only](LICENSE). Corral's name and floral-hat artwork have a separate [brand policy](BRAND_POLICY.md). Dependencies and assistant-provider marks retain their own licenses and ownership; see [third-party notices](THIRD_PARTY_NOTICES.md).
