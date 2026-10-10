# Privacy

Corral's Apple apps are clients of a host you pair with. Session creation, input, terminal control and other agent actions execute on that host. Pairing is an authorization grant, not a read-only link.

- The client exchanges session metadata, conversation history, terminal output and your input with the selected host. Image attachments you send become host-side input.
- Device keys and paired-host credentials are stored in Apple Keychain. Bounded client caches and preferences live in the app's local storage; history may remain available after a connection closes.
- End-to-end encryption protects session traffic and push text. A configured relay sees routing identities, timing, connection addresses and traffic volume. Encryption does not remove those metadata exposures.
- Remote messages can authorize agents to act with the host user's permissions. Review the host's assistant configuration and pairing grants before connecting an untrusted device.
- APNs receives the encrypted notification payload and delivery metadata when push is configured. Camera/photo access is used for pairing and attachments after the system grants access.
- Open-source builds use your configured hosts and self-hosted relay. They do not embed a maintainer-hosted relay, signing key, telemetry account or update feed.
- Removing the app does not promise erasure of Keychain entries or host-side agent histories. Review pairing and storage on each endpoint when decommissioning a device.

Never publish real keys, pairing codes, host addresses, account tokens or private conversations in issues, screenshots or logs. Security-sensitive findings belong in private security reporting.
