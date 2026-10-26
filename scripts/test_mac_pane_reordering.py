#!/usr/bin/env python3
"""Compile production pane payload/move methods and exercise insertion semantics."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "macOS/Panes/MacPaneReordering.swift").read_text()
payload = source[source.index("nonisolated struct MacPaneDrag"):source.index("/// Native dragging")]
workspace = (ROOT / "macOS/Workspace/MacWorkspace.swift").read_text()
methods = workspace[workspace.index("    func paneDrag(for key:"):workspace.index("    func focusPane(at index:")]
probe = '''
import Foundation
import CoreTransferable
import UniformTypeIdentifiers

PAYLOAD

@MainActor final class MacWorkspace {
    let paneDragWorkspaceID = UUID()
    var hostID: String? = "host-a"
    var paneKeys = ["a", "b", "c", "d"]
    var focusedKey = "c"
    var leavingPanes: [String: Int] = [:]
    var glides: [[String]] = []
    var synced: [[String]] = []
    func glide(from keys: [String]) { glides.append(keys) }
    func syncGroup() { synced.append(paneKeys) }
METHODS
}

@main struct Probe {
    @MainActor static func main() throws {
        var moves = 0
        for count in 2...4 {
            for from in 0..<count {
                for to in 0..<count where from != to {
                    let workspace = MacWorkspace()
                    let original = Array(["a", "shell:local", "c", "d"].prefix(count))
                    workspace.paneKeys = original
                    guard let payload = workspace.paneDrag(for: original[from]) else { fatalError("missing payload") }
                    let roundtrip = try JSONDecoder().decode(MacPaneDrag.self, from: JSONEncoder().encode(payload))
                    var expected = original
                    expected.insert(expected.remove(at: from), at: to)
                    precondition(workspace.reorderPane(roundtrip, to: original[to]))
                    precondition(workspace.paneKeys == expected)
                    precondition(workspace.focusedKey == "c", "focus must stay on its identity")
                    precondition(workspace.glides == [original] && workspace.synced == [expected])
                    precondition(!workspace.reorderPane(roundtrip, to: original[to]), "stale payload")
                    moves += 1
                }
            }
        }
        let workspace = MacWorkspace()
        guard let fourth = workspace.paneDrag(for: "d") else { fatalError("missing fourth") }
        precondition(workspace.reorderPane(fourth, to: "b"))
        precondition(workspace.paneKeys == ["a", "d", "b", "c"])
        guard let first = workspace.paneDrag(for: "a") else { fatalError("missing first") }
        precondition(!workspace.reorderPane(first, to: "a"))
        precondition(!workspace.reorderPane(first, to: "missing"))
        precondition(!MacWorkspace().reorderPane(first, to: "c"), "foreign workspace")
        workspace.hostID = "host-b"
        precondition(!workspace.reorderPane(first, to: "c"), "foreign host")
        workspace.hostID = "host-a"
        workspace.leavingPanes["closing"] = 1
        precondition(workspace.paneDrag(for: "a") == nil)
        precondition(!workspace.reorderPane(first, to: "c"), "closing pane")
        workspace.leavingPanes = [:]
        workspace.paneKeys = ["a"]
        precondition(workspace.paneDrag(for: "a") == nil)
        precondition(workspace.paneDrag(for: "missing") == nil)
        precondition(!workspace.reorderPane(first, to: "c"), "changed roster")
        precondition(workspace.synced.count == 1, "rejected drops cannot sync")
        print("PASS: \\(moves) bidirectional insertion moves; 4→2; payload roundtrip; focus; shell; no-op/stale/foreign/closing/single guards")
    }
}
'''.replace("PAYLOAD", payload).replace("METHODS", methods)
with tempfile.TemporaryDirectory(prefix="corral-pane-reorder-") as directory:
    swift = Path(directory) / "Probe.swift"
    swift.write_text(probe)
    binary = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", str(swift), "-o", binary], check=True)
    subprocess.run([binary], check=True)
