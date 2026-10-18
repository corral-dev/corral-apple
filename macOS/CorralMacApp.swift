import AppKit
import SwiftUI
import UserNotifications

@main
enum CorralMacEntry {
    static func main() {
        MacScrollerPreference.install()
        CorralMacApp.main()
    }
}

struct CorralMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appModel = AppModel()
    @State private var commands = MacCommandCenter()
    @State private var zoom = MacInterfaceZoom()
    @State private var minimumWidth: CGFloat = Self.baseMinimumWidth

    private static let baseMinimumWidth: CGFloat = 760

    /// Debug inspection captures keep precedence; otherwise the Settings choice
    /// applies (nil follows the system appearance).
    private var resolvedColorScheme: ColorScheme? {
        #if DEBUG
        InspectionLaunchOptions.forcedColorScheme ?? appModel.appAppearance.colorScheme
        #else
        appModel.appAppearance.colorScheme
        #endif
    }

    /// The in-app language as a SwiftUI locale (system follows the OS).
    /// Foundation `String(localized:)` strings pick the same language up from
    /// AppleLanguages on the next launch.
    private var resolvedLocale: Locale {
        appModel.appLanguage.locale ?? Locale.autoupdatingCurrent
    }

    init() {
        #if CORRAL_DIRECT_DOWNLOAD
        // Keep scheduled updates alive independently of menus and Settings.
        _ = MacUpdater.shared
        #endif
        // Install before launch finishes so a cold-launch notification tap is retained.
        UNUserNotificationCenter.current().delegate = MacNotifications.shared
    }

    var body: some Scene {
        Window(Text(verbatim: "Corral"), id: "main") {
            MacRootView()
                .modifier(MacZoomScope(zoom: zoom))
                .onAppear { MacNotifications.shared.configure(model: appModel) }
                .environment(appModel)
                .environment(commands)
                .tint(Palette.accent)
                .focusEffectDisabled()
                .environment(\.locale, resolvedLocale)
                .preferredColorScheme(resolvedColorScheme)
                .frame(minWidth: minimumWidth, minHeight: 480)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        appModel.handleSceneBecameActive()
                        Task { await MacNotifications.shared.refreshAuthorization() }
                    }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    appModel.handleSceneBecameActive()
                }
                .onPreferenceChange(WindowMinimumWidthKey.self) { required in
                    minimumWidth = max(Self.baseMinimumWidth, required)
                }
                #if DEBUG
                .draftImageInspection()
                // Standalone polish fixture: real question/error views over the
                // main window, no pairing or session. Captured by window id.
                .overlay {
                    if ProcessInfo.processInfo.arguments.contains("-CorralInspectQuestionPolish") {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            QuestionPolishFixtureView()
                                .frame(width: 480)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(.systemGroupedBackground))
                    }
                }
                #if CORRAL_DIRECT_DOWNLOAD
                .modifier(MacUpdateInspection())
                #endif
                .task { await MacResizeInspection.runIfRequested() }
                #endif
        }
        .defaultSize(width: 1180, height: 760)
        // The window's minimum follows the content: sidebar plus every pane.
        .windowResizability(.contentMinSize)
        // The main window always opens at launch, even if it was closed when the
        // app last quit (a restored-closed state otherwise leaves no window).
        .defaultLaunchBehavior(.presented)
        .windowToolbarStyle(.unified)
        .commands {
            MacCommands(center: commands)
            MacZoomCommands(zoom: zoom)
            #if CORRAL_DIRECT_DOWNLOAD
            MacUpdateCommands()
            #endif
        }

        Settings {
            MacSettingsView()
                .modifier(MacZoomScope(zoom: zoom))
                .environment(appModel)
                .environment(\.locale, resolvedLocale)
                .preferredColorScheme(resolvedColorScheme)
                .tint(Palette.accent)
                .focusEffectDisabled()
        }
    }
}

/// Menu and keyboard requests routed to the main window. Each counter bump is
/// one request; the window observes the change and performs it in place.
@MainActor
@Observable
final class MacCommandCenter {
    var newSessionRequest = 0
    var closePaneRequest = 0
    var toggleViewRequest = 0
    var searchRequest = 0
    var pinRequest = 0
    /// Focus-pane requests need a counter, not an assigned index: pressing ⌘2
    /// twice before the window clears the value must deliver two requests.
    var focusPaneIndex = 0
    var focusPaneRequest = 0
    var pairRequest = 0
    var nextAttentionRequest = 0
    var previousAttentionRequest = 0
    var toggleTerminalRequest = 0
    var newTerminalTabRequest = 0
    /// The machine runs project shells and this pairing may use them.
    var canUseTerminal = false
    /// Whether the main window currently has a connected, writable machine.
    var canCreateSession = false
    var hasFocusedPane = false
    var focusedSessionPinned = false
}

/// Command-key shortcuts (owner decision 2026-10-04): every Control
/// combination stays with the agent in terminal view.
struct MacCommands: Commands {
    let center: MacCommandCenter

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("sessions.new") { center.newSessionRequest += 1 }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!center.canCreateSession)
            Button("mac.pane.close") { center.closePaneRequest += 1 }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(!center.hasFocusedPane)
            Divider()
            Button("mac.pair_machine") { center.pairRequest += 1 }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("mac.search.title") { center.searchRequest += 1 }
                .keyboardShortcut("f", modifiers: .command)
        }
        CommandMenu("mac.menu.session") {
            Button("mac.pane.toggle_view") { center.toggleViewRequest += 1 }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!center.hasFocusedPane)
            Button { center.pinRequest += 1 } label: {
                Label(center.focusedSessionPinned ? "mac.session.unpin" : "mac.session.pin",
                      systemImage: center.focusedSessionPinned ? "pin.slash" : "pin")
            }
                .labelStyle(.titleAndIcon)
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!center.hasFocusedPane)
            Divider()
            ForEach(0..<4, id: \.self) { index in
                Button("mac.pane.focus \(index + 1)") {
                    center.focusPaneIndex = index
                    center.focusPaneRequest += 1
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("mac.menu.next_needs_you") { center.nextAttentionRequest += 1 }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("mac.menu.previous_needs_you") { center.previousAttentionRequest += 1 }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            // ⌥F12 as in the IntelliJ terminal tool window (owner reference).
            Button("terminal.panel.toggle") { center.toggleTerminalRequest += 1 }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: .option)
                .disabled(!center.canUseTerminal)
            Button("terminal.pane.new") { center.newTerminalTabRequest += 1 }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(!center.canUseTerminal)
        }
        SidebarCommands()
    }
}
