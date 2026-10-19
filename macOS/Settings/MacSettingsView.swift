import SwiftUI
import UserNotifications

/// Native toolbar tabs, each sized to its complete grouped form.
struct MacSettingsView: View {
    private enum Pane: String {
        case general, notifications, machines
    }

    @AppStorage("corral.mac.settingsPane") private var selection = Pane.general

    var body: some View {
        TabView(selection: $selection) {
            Tab("mac.settings.general", systemImage: "gearshape", value: Pane.general) {
                MacGeneralSettings()
                    .modifier(MacZoomContent())
            }
            Tab("settings.notifications", systemImage: "bell", value: Pane.notifications) {
                MacNotificationSettings()
                    .modifier(MacZoomContent())
            }
            Tab("nav.hosts", systemImage: "desktopcomputer", value: Pane.machines) {
                MacMachinesSettings()
                    .modifier(MacZoomContent())
            }
        }
        .interfaceFrame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MacGeneralSettings: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacInterfaceZoom.self) private var zoom
    @AppStorage(MacWorkspace.newSessionModeKey) private var newSessionMode = MacWorkspace.PaneMode.chat

    var body: some View {
        @Bindable var model = appModel
        Form {
            Section("settings.display") {
                Picker("settings.language", selection: $model.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                Picker("settings.appearance", selection: $model.appAppearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                Picker("mac.zoom.size", selection: Binding(
                    get: { zoom.percentage }, set: { zoom.setPercentage($0) }
                )) {
                    ForEach(Array(stride(from: MacInterfaceZoom.minimum, through: MacInterfaceZoom.maximum,
                                         by: MacInterfaceZoom.step)), id: \.self) { percentage in
                        Text(verbatim: "\(percentage)%").tag(percentage)
                    }
                }
                if zoom.persistenceFailed {
                    Text("mac.zoom.save_failed").foregroundStyle(.red)
                }
                Picker("settings.session_text_size", selection: $model.sessionTextSize) {
                    ForEach(SessionTextSize.allCases) { size in
                        Text(size.title).tag(size)
                    }
                }
                Picker("mac.settings.new_session_view", selection: $newSessionMode) {
                    Text("mac.pane.chat").tag(MacWorkspace.PaneMode.chat)
                    Text("mac.pane.terminal").tag(MacWorkspace.PaneMode.terminal)
                }
                .pickerStyle(.segmented)
            }
            Section("settings.connection") {
                Toggle("hosts.prefer_direct", isOn: $model.preferDirectConnection)
            }
            #if CORRAL_DIRECT_DOWNLOAD
            MacUpdateSettings()
            #endif
            Section {
                MacSettingsAboutRow()
            }
        }
        .modifier(MacSettingsFormStyle())
    }
}

private struct MacNotificationSettings: View {
    @State private var notifications = MacNotifications.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Toggle("settings.notifications", isOn: Binding(
                    get: { notifications.enabled },
                    set: { value in Task { await notifications.setEnabled(value) } }
                ))
                if notifications.enabled {
                    Toggle("settings.notifications.waiting", isOn: $notifications.waiting)
                    Toggle("settings.notifications.completed", isOn: $notifications.completed)
                    Toggle("settings.notifications.aborted", isOn: $notifications.aborted)
                    if notifications.authorization == .denied {
                        LabeledContent {
                            Button("action.open_settings") { notifications.openSystemSettings() }
                        } label: {
                            Label("settings.notifications.denied", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                        }
                    } else if notifications.authorization == .notDetermined {
                        LabeledContent("settings.notifications") {
                            Button("settings.notifications.enable") {
                                Task { await notifications.setEnabled(true) }
                            }
                        }
                    }
                }
                if let failure = notifications.failure {
                    Text(verbatim: failure).foregroundStyle(.red)
                }
            }
        }
        .modifier(MacSettingsFormStyle())
        .task { await notifications.refreshAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await notifications.refreshAuthorization() } }
        }
    }
}

private struct MacMachinesSettings: View {
    @Environment(AppModel.self) private var appModel
    @State private var selectedHostID: String?
    @State private var customName = ""
    @State private var fingerprint = ""
    @State private var confirmUnpair = false

    private var selectedHost: HostInfo? {
        appModel.hosts.first { $0.hostID == selectedHostID } ?? appModel.hosts.first
    }

    var body: some View {
        Form {
            if appModel.hosts.isEmpty {
                Text("hosts.empty.title")
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    Picker("mac.settings.machine", selection: Binding(
                        get: { selectedHost?.hostID ?? "" },
                        set: { selectedHostID = $0 }
                    )) {
                        ForEach(appModel.hosts) { host in
                            Text(verbatim: host.displayName).tag(host.hostID)
                        }
                    }
                    if let host = selectedHost {
                        TextField("hosts.custom_name", text: $customName,
                                  prompt: Text("hosts.custom_name.placeholder"))
                            .autocorrectionDisabled()
                            .onSubmit { saveCustomName(host) }
                            .help(Text("hosts.custom_name.default_value \(host.name)"))
                    }
                }
                if let host = selectedHost {
                    Section("mac.settings.device_fingerprint") {
                        Text(verbatim: fingerprint.isEmpty ? "…" : fingerprint)
                            .interfaceFont(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Section {
                        LabeledContent {
                            Button("hosts.unpair", role: .destructive) { confirmUnpair = true }
                        } label: {
                            Text(verbatim: host.displayName)
                        }
                    }
                    .confirmationDialog("settings.unpair_confirm.title", isPresented: $confirmUnpair, titleVisibility: .visible) {
                        Button("hosts.unpair", role: .destructive) {
                            appModel.removeHost(host)
                            selectedHostID = appModel.hosts.first?.hostID
                        }
                        Button("action.cancel", role: .cancel) {}
                    } message: {
                        Text("settings.unpair_confirm.message")
                    }
                }
            }
        }
        .modifier(MacSettingsFormStyle())
        .task(id: selectedHost?.hostID) {
            fingerprint = (try? HostStore.shared.devicePublicKeyHex()) ?? ""
            customName = selectedHost.flatMap { HostStore.shared.host(for: $0.hostID)?.customName } ?? ""
        }
    }

    private func saveCustomName(_ host: HostInfo) {
        HostStore.shared.setCustomName(hostID: host.hostID, name: customName)
        appModel.refreshHosts()
    }
}

/// The system Form owns rows and control alignment; only its viewport is fitted.
private struct MacSettingsFormStyle: ViewModifier {
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                ceil(geometry.contentSize.height)
            } action: { _, height in
                if height > 0 { contentHeight = height }
            }
            .scrollDisabled(true)
            .frame(height: contentHeight)
    }
}

private struct MacSettingsAboutRow: View {
    #if CORRAL_DIRECT_DOWNLOAD
    @State private var updater = MacUpdater.shared
    #endif

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interfaceFrame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Corral").fontWeight(.medium)
                Text(verbatim: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    .interfaceFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            #if CORRAL_DIRECT_DOWNLOAD
            Button("mac.updates.check") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            #endif
            Button("mac.settings.quit") { NSApp.terminate(nil) }
        }
    }
}
