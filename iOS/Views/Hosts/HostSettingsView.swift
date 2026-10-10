#if os(iOS)
import SwiftUI
import UserNotifications

struct HostSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let host: HostInfo
    @State private var confirmUnpair = false
    @State private var fingerprint = ""
    @State private var customName = ""
    @State private var customNameSaved = ""
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationPreferences = CompletionNotificationPreferences.shared
    @State private var hapticScope = HapticScope()

    var body: some View {
        Form {
            Section("settings.display") {
                NavigationLink {
                    SessionTextSizeSettingsView()
                } label: {
                    LabeledContent("settings.session_text_size") {
                        Text(appModel.sessionTextSize.title)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("settings.notifications") {
                notificationSettingsRow
                Toggle("settings.notifications.completed", isOn: $notificationPreferences.completed)
                Toggle("settings.notifications.aborted", isOn: $notificationPreferences.aborted)
                if let error = notificationPreferences.registrationError {
                    Text(verbatim: error).foregroundStyle(.red)
                    Button("action.retry") { Task { await syncNotificationPreferences() } }
                }
            }

            Section("settings.connection") {
                Toggle("hosts.prefer_direct", isOn: Bindable(appModel).preferDirectConnection)
            }

            Section("hosts.device_fingerprint") {
                Text(fingerprint.isEmpty ? "…" : fingerprint)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Section("hosts.custom_name") {
                TextField("hosts.custom_name.placeholder", text: $customName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { saveCustomName() }
                if !customNameSaved.isEmpty {
                    Text("hosts.custom_name.default_value \(customNameSaved)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("hosts.unpair", role: .destructive) {
                    confirmUnpair = true
                }
            }
        }
        .navigationTitle(currentDisplayName)
        .hapticScope(hapticScope)
        .confirmationDialog("settings.unpair_confirm.title", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("hosts.unpair", role: .destructive) {
                appModel.removeHost(host)
                if !appModel.hosts.contains(where: { $0.hostID == host.hostID }) {
                    HapticFeedback.shared.emit(.committed, scope: hapticScope)
                }
                dismiss()
            }
            Button("action.cancel", role: .cancel) {}
        } message: {
            Text("settings.unpair_confirm.message")
        }
        .task {
            fingerprint = (try? HostStore.shared.devicePublicKeyHex()) ?? ""
            loadCustomName()
            await refreshNotificationStatus()
        }
        .onChange(of: notificationPreferences.completed) { _, _ in
            Task { await syncNotificationPreferences() }
        }
        .onChange(of: notificationPreferences.aborted) { _, _ in
            Task { await syncNotificationPreferences() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshNotificationStatus() }
        }
    }

    @ViewBuilder
    private var notificationSettingsRow: some View {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral:
            LabeledContent("settings.notifications") {
                Text("settings.notifications.on")
                    .foregroundStyle(.secondary)
            }
        case .denied:
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("settings.notifications.denied")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("action.open_settings") {
                    PushRegistrar.shared.openSystemSettings()
                }
            }
        case .notDetermined:
            Button("settings.notifications.enable") {
                Task {
                    await PushRegistrar.shared.requestAuthorizationIfNeeded()
                    await refreshNotificationStatus()
                }
            }
        @unknown default:
            EmptyView()
        }
    }

    private func syncNotificationPreferences() async {
        guard appModel.isConnected(to: host), let client = appModel.client else { return }
        await PushRegistrar.shared.registerIfNeeded(client: client)
    }

    private func refreshNotificationStatus() async {
        await PushRegistrar.shared.refreshAuthorizationStatus()
        notificationStatus = PushRegistrar.shared.authorizationStatus
    }

    /// 设置页标题与输入框初值：别名优先，否则默认名。
    private var currentDisplayName: String {
        let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? host.displayName : trimmed
    }

    private func loadCustomName() {
        let stored = HostStore.shared.host(for: host.hostID)
        customName = stored?.customName ?? ""
        customNameSaved = stored?.name ?? host.name
    }

    /// 回车即保存；清空即恢复默认名。只写本机 paired-hosts.json，不发服务端。
    private func saveCustomName() {
        HostStore.shared.setCustomName(hostID: host.hostID, name: customName)
        appModel.refreshHosts()
        loadCustomName()
    }
}

struct SessionTextSizeSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.sm) {
                    MessageBubbleView(
                        message: RichMessage(
                            seq: 1,
                            role: "user",
                            text: String(localized: "settings.session_text_size.preview.user")
                        )
                    )
                    MessageBubbleView(
                        message: RichMessage(
                            seq: 2,
                            role: "assistant",
                            text: String(localized: "settings.session_text_size.preview.assistant")
                        )
                    )
                }
                .padding(Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))

            VStack(spacing: Space.sm) {
                Text(appModel.sessionTextSize.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: Space.md) {
                    Text("A")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(
                        value: Binding(
                            get: { appModel.sessionTextSize.sliderIndex },
                            set: { appModel.sessionTextSize = SessionTextSize.from(sliderIndex: $0) }
                        ),
                        in: 0 ... Double(SessionTextSize.allCases.count - 1),
                        step: 1
                    )
                    .accessibilityLabel(Text("settings.session_text_size"))
                    .accessibilityValue(Text(appModel.sessionTextSize.title))
                    Text("A")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Space.base)
            .padding(.vertical, Space.md)
            .background(.bar)
        }
        .environment(\.sessionTextScale, appModel.sessionTextSize.scale)
        .navigationTitle("settings.session_text_size")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}
#endif
