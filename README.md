**Languages:** English | [简体中文](README.zh-CN.md)

<p align="center"><img src="docs/images/corral-icon.png" alt="Corral" width="112" height="112"></p>
<h1 align="center">Corral for iPhone and Mac</h1>
<p align="center"><strong>Keep your coding agents moving, wherever you are.</strong></p>

Read replies, answer questions, and send the next instruction to Claude Code, Codex, OpenCode, Cursor, or Pi from a native Apple client. Your agents run on a [Corral host](https://github.com/corral-dev/corral) on macOS or Linux.

- **See who needs you.** Follow all five assistants in one session list.
- **Work across sessions.** Open up to four panes side by side on Mac.
- **Choose your view.** Switch each Mac pane between chat and the agent's terminal.
- **Find your work.** Filter by project and search conversation text.
- **Keep typing.** Use keyboard shortcuts on Mac, or reply from your iPhone.

## Install

The clients are a **source beta**: build with Xcode. Public App Store and TestFlight downloads are not available yet.

| Client | Requirements |
| --- | --- |
| Mac | macOS 26+, Xcode with the macOS 26 SDK |
| iPhone | iOS 17+, Xcode, your own signing team and a physical iPhone |
| Host | [Corral CLI](https://github.com/corral-dev/corral#install) on macOS or Linux, with an installed coding assistant |

### Mac

With Xcode and its command-line tools installed:

```bash
curl -fsSL https://raw.githubusercontent.com/corral-dev/corral-apple/main/install.sh | bash
```

Open Corral from `~/Applications`. To choose another installation directory, set `CORRAL_APP_DIR` when running the installer.

### iPhone

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen), then clone the source and generate the Xcode project:

```bash
git clone https://github.com/corral-dev/corral-apple.git
cd corral-apple
xcodegen generate
```

Open `Corral.xcodeproj`, choose your own team and unique bundle identifiers, and build for your iPhone. Follow the [build and signing guide](docs/PUBLIC_BUILD_GUIDE.md) for the shared Keychain group and notification extension. Push notifications require an Apple Developer membership.

## Pair with your host

On the machine that runs your agents:

```bash
brew install x0c/tap/corral
corral remote pair
```

If Corral is already installed, run only the second command. [Other CLI installation options](https://github.com/corral-dev/corral#install) are available.

On the same local network, open the Apple client and scan or paste the pairing code. Pairing lets the client read and act on your host's sessions; use `corral remote pair --readonly` for viewing only. Keep the code private. The host must remain awake for agents and remote access to keep working.

## Access from another network

Run your own [Corral relay](https://github.com/corral-dev/corral-relay#quick-start) and configure its `wss://` address on the host. Same-network access works directly. Open-source clients use your configured relay; a shared hosted relay is not included.

For iPhone notifications, configure APNs on that relay with credentials matching your own app identity. Without APNs, conversations still update while the client is open.

## Privacy

Session traffic and notification text are end-to-end encrypted. The relay sees routing identities, connection timing and byte counts. Device keys are stored in Keychain; conversations can be cached on the client for reopening history. See [PRIVACY.md](PRIVACY.md).

## Help and contribute

- [Build and signing guide](docs/PUBLIC_BUILD_GUIDE.md)
- [Report a bug or request a feature](https://github.com/corral-dev/corral-apple/issues/new/choose)
- [Contributing](CONTRIBUTING.md) and the [contributor agreement](CLA.md)

Remove private conversations, machine addresses and pairing credentials from public reports. For vulnerabilities, use [private security reporting](https://github.com/corral-dev/corral-apple/security/advisories/new).

## License

[GPL-3.0-only](LICENSE). Corral's name and floral-hat artwork have a separate [brand policy](BRAND_POLICY.md). Dependencies and assistant-provider marks retain their own licenses and ownership; see [third-party notices](THIRD_PARTY_NOTICES.md).
