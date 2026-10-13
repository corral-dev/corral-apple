import SwiftUI
import UserNotifications

/// Standard Settings window (⌘,): general preferences and paired machines.
struct MacSettingsView: View {
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            Tab("mac.settings.general", systemImage: "gearshape", value: 0) {
                MacGeneralSettings()
                    .modifier(MacZoomContent())
            }
            Tab("nav.hosts", systemImage: "desktopcomputer", value: 1) {
                MacMachinesSettings()
                    .modifier(MacZoomContent())
            }
        }
        .interfaceFrame(width: 520)
        .interfaceFrame(minHeight: 340)
    }
}

private struct MacGeneralSettings: View {
    @Environment(AppModel.self) private var appModel
    @Environment(MacInterfaceZoom.self) private var zoom
    @State private var notifications = MacNotifications.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(MacWorkspace.newSessionModeKey) private var newSessionMode = MacWorkspace.PaneMode.chat

    var body: some View {
        @Bindable var model = appModel
        Form {
            Section("settings.display") {
                Picker("mac.zoom.size", selection: Binding(
                    get: { zoom.percentage }, set: { zoom.setPercentage($0) }
                )) {
                    ForEach(Array(stride(from: MacInterfaceZoom.minimum, through: MacInterfaceZoom.maximum,
                                         by: MacInterfaceZoom.step)), id: \.self) { percentage in
                        Text(verbatim: "\(percentage)%").tag(percentage)
                    }
                }
                .nativeOverlayScrollers()
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
            Section("settings.notifications") {
                Toggle("settings.notifications", isOn: Binding(
                    get: { notifications.enabled },
                    set: { value in Task { await notifications.setEnabled(value) } }
                ))
                if notifications.enabled {
                    Toggle("settings.notifications.waiting", isOn: $notifications.waiting)
                    Toggle("settings.notifications.completed", isOn: $notifications.completed)
                    Toggle("settings.notifications.aborted", isOn: $notifications.aborted)
                    if notifications.authorization == .denied {
                        Text("settings.notifications.denied").foregroundStyle(.secondary)
                        Button("action.open_settings") { notifications.openSystemSettings() }
                    } else if notifications.authorization == .notDetermined {
                        Button("settings.notifications.enable") {
                            Task { await notifications.setEnabled(true) }
                        }
                    }
                }
                if let failure = notifications.failure {
                    Text(verbatim: failure).foregroundStyle(.red)
                }
            }
            Section("settings.connection") {
                Toggle("hosts.prefer_direct", isOn: $model.preferDirectConnection)
            }
            #if CORRAL_DIRECT_DOWNLOAD
            MacUpdateSettings()
            #endif
        }
        .formStyle(.grouped)
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
                    .nativeOverlayScrollers()
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
                    .nativeOverlayScrollers()
                }
                if let host = selectedHost {
                    Section("hosts.custom_name") {
                        TextField("hosts.custom_name.placeholder", text: $customName)
                            .autocorrectionDisabled()
                            .onSubmit { saveCustomName(host) }
                        Text("hosts.custom_name.default_value \(host.name)")
                            .interfaceFont(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section("hosts.device_fingerprint") {
                        Text(verbatim: fingerprint.isEmpty ? "…" : fingerprint)
                            .interfaceFont(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Section {
                        Button("hosts.unpair", role: .destructive) { confirmUnpair = true }
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
        .formStyle(.grouped)
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
