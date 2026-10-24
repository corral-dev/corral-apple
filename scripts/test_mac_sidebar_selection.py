#!/usr/bin/env python3
"""Exercise the production sidebar marker with a real SwiftUI List, without input events."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class State {
    var selection: Set<String> = ["b"]
    var rows = ["a", "b", "c", "d"]
    var generation = 0
    var revision = 0
    var navigation = 0
    var focus = "b"
}

struct Fixture: View {
    let state: State
    var body: some View {
        List(selection: Binding(get: { state.selection }, set: { keys in
            guard !NativeSidebarSelection.isReconcilingSelection else { return }
            guard !keys.isEmpty else { state.selection = [state.focus]; return }
            guard keys != state.selection else { return }
            state.selection = keys
            if keys.count == 1 { state.navigation += 1 }
        })) {
            Section("Today") {
                ForEach(state.rows, id: \.self) { key in
                    Text("Session \(key) / \(state.revision)")
                        .background(NativeSidebarSelection(selectedState: {
                            guard state.rows.contains(key) else { return nil }
                            return state.selection.contains(key)
                        }, debugKey: key))
                        .tag(key)
                }
            }
        }.listStyle(.sidebar).id(state.generation)
    }
}

@main struct Probe {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let state = State()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Fixture(state: state))
        window.contentView = host
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        func settle() {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            }
        }
        func table() -> NSOutlineView {
            descendants(host).compactMap { $0 as? NSOutlineView }.first!
        }
        func keys() -> Set<String> {
            Set(descendants(host).compactMap { $0 as? NativeSidebarSelection.SelectionAppearanceView }
                .filter { $0.debugRowState()?.selected == true }.compactMap(\.debugKey))
        }
        func indexes(_ requested: Set<String>) -> IndexSet {
            IndexSet(descendants(host).compactMap { $0 as? NativeSidebarSelection.SelectionAppearanceView }
                .filter { requested.contains($0.debugKey ?? "") }.compactMap { $0.debugRowState()?.row })
        }
        func expect(_ label: String, _ expected: Set<String>) {
            settle()
            precondition(state.selection == expected, "\(label): model \(state.selection) != \(expected)")
            precondition(keys() == expected, "\(label): native \(keys()) != \(expected)")
            print("PASS \(label): model/native \(expected.sorted())")
        }
        expect("initial current session", ["b"])
        let responder = window.firstResponder
        let offset = table().enclosingScrollView!.contentView.bounds.origin
        table().selectRowIndexes([], byExtendingSelection: false)
        expect("cancel last native selection", ["b"])
        precondition(state.navigation == 0 && window.firstResponder === responder)
        precondition(table().enclosingScrollView!.contentView.bounds.origin == offset)
        table().selectRowIndexes(indexes(["a", "b", "c"]), byExtendingSelection: false)
        expect("native batch", ["a", "b", "c"])
        precondition(state.navigation == 0)
        state.revision += 1
        expect("metadata preserves batch", ["a", "b", "c"])
        state.generation += 1
        expect("mounted list replacement preserves batch", ["a", "b", "c"])
        state.rows.reverse()
        expect("row reordering preserves identity", ["a", "b", "c"])
        state.selection = ["b"]
        expect("clear batch returns to current", ["b"])
        table().selectRowIndexes(indexes(["d"]), byExtendingSelection: false)
        expect("ordinary single navigation", ["d"])
        precondition(state.navigation == 1)
        state.selection = ["b"]
        expect("pane reactivation", ["b"])
        for _ in 0..<10 {
            table().selectRowIndexes([], byExtendingSelection: false)
            expect("repeated empty reconciliation", ["b"])
            state.generation += 1
            expect("repeated mounted replacement", ["b"])
        }
        precondition(state.navigation == 1, "native repair synthesized a visit")
        print("PASS no pointer/keyboard events, extra navigation, focus change or scroll")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="corral-mac-sidebar-selection-") as directory:
    source = Path(directory) / "Probe.swift"
    source.write_text(PROBE)
    binary = Path(directory) / "probe"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-DDEBUG", "-parse-as-library",
        str(ROOT / "macOS/Sidebar/NativeSidebarSelection.swift"), str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
