#!/usr/bin/env python3
"""Compile the production drag and motion methods, including deferred resets.

Transport is recorded; geometry, insertion, interruption and settling run the
actual workspace implementation. This does not establish gesture activation.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "macOS/Panes/MacPaneReordering.swift").read_text()
geometry = source[source.index("nonisolated struct MacPaneDragGeometry"):source.index("/// The header's leading strip")]
workspace = (ROOT / "macOS/Workspace/MacWorkspace.swift").read_text()
state = workspace[workspace.index("    struct PaneReorder: Equatable {"):workspace.index("    private(set) var paneReorder:")]
methods = workspace[workspace.index("    var canReorderPanes: Bool"):workspace.index("    func focusPane(at index:")]
motion = workspace[workspace.index("    private func glide(from before:"):
                   workspace.index("    // MARK: - Keyboard focus follows")]
motion = motion.replace("private func glide(", "private func productionGlide(", 1)
probe = '''
import AppKit
import SwiftUI

GEOMETRY

enum MacMotion {
    static let state = Animation.linear(duration: 0)
    static let paneGlide = Animation.linear(duration: 0)
    static var paneGlideSeconds = 0.0
    static func seconds(_ base: Double) -> Double { base }
}

@MainActor enum MotionEnvironment { static var reduceMotion = false }

@MainActor final class MacWorkspace {
STATE
    var paneReorder: PaneReorder?
    var liftedPane: String?
    var paneKeys = ["a", "b", "c", "d"]
    var focusedKey: String? = "c"
    var leavingPanes: [String: Int] = [:]
    var paneShifts: [String: CGFloat] = [:]
    var splitWidth: CGFloat = 400
    var glideSerial = 0
    var glides: [(before: [String], excluded: String?)] = []
    var synced: [[String]] = []
    var drawnPaneKeys: [String] { paneKeys }
    func glide(from keys: [String], entering: String? = nil, excluding dragged: String? = nil) {
        glides.append((keys, dragged))
        productionGlide(from: keys, entering: entering, excluding: dragged)
    }
    func syncGroup() { synced.append(paneKeys) }
METHODS
MOTION
}

@main struct Probe {
    @MainActor static func main() async {
        var moves = 0
        for count in 2...4 {
            for from in 0..<count {
                for to in 0..<count where from != to {
                    let workspace = MacWorkspace()
                    let original = Array(["a", "shell:local", "c", "d"].prefix(count))
                    workspace.paneKeys = original
                    workspace.splitWidth = CGFloat(count) * 100
                    workspace.beginPaneDrag(original[from])
                    // Pointer over the target slot's centre, reached in small steps.
                    let travel = CGFloat(to - from) * 100
                    for step in 1...10 { workspace.dragPane(original[from], travel: travel * CGFloat(step) / 10) }
                    var expected = original
                    expected.insert(expected.remove(at: from), at: to)
                    precondition(workspace.paneKeys == expected, "live order \\(workspace.paneKeys) != \\(expected)")
                    precondition(abs(workspace.paneReorder!.offset) < 0.5, "pane sits under the pointer")
                    precondition(workspace.liftedPane == original[from])
                    precondition(workspace.synced.isEmpty, "no group write while dragging")
                    precondition(workspace.glides.allSatisfy { $0.excluded == original[from] })
                    workspace.endPaneDrag(original[from])
                    precondition(workspace.paneReorder == nil && workspace.paneKeys == expected)
                    precondition(workspace.synced == [expected], "one write on release")
                    precondition(workspace.focusedKey == "c", "focus stays on its identity")
                    workspace.endPaneDrag(original[from])
                    precondition(workspace.synced.count == 1, "release is idempotent")
                    moves += 1
                }
            }
        }

        // 4 over 2 → insertion, not a swap.
        let w = MacWorkspace()
        w.beginPaneDrag("d")
        for step in 1...20 { w.dragPane("d", travel: -200 * CGFloat(step) / 20) }
        precondition(w.paneKeys == ["a", "d", "b", "c"])
        w.endPaneDrag("d")
        precondition(w.synced == [["a", "d", "b", "c"]])

        // Neighbours give way only once half covered.
        let half = MacWorkspace()
        half.beginPaneDrag("a")
        half.dragPane("a", travel: 49)
        precondition(half.paneKeys == ["a", "b", "c", "d"])
        half.dragPane("a", travel: 51)
        precondition(half.paneKeys == ["b", "a", "c", "d"])
        half.dragPane("a", travel: 10)
        precondition(half.paneKeys == ["a", "b", "c", "d"], "dragging back restores live")
        half.endPaneDrag("a")
        precondition(half.synced.isEmpty, "an unchanged release writes nothing")
        precondition(half.paneShifts["a"] == 10, "released pane glides home from the pointer")

        // Clamped to the split's edges.
        let edge = MacWorkspace()
        edge.beginPaneDrag("b")
        edge.dragPane("b", travel: 5000)
        precondition(edge.paneKeys == ["a", "c", "d", "b"])
        precondition(edge.paneReorder!.offset == 0, "cannot leave the trailing edge")
        edge.dragPane("b", travel: -5000)
        precondition(edge.paneKeys == ["b", "a", "c", "d"] && edge.paneReorder!.offset == 0)

        // A cancelled gesture restores the starting order and writes nothing.
        let cancel = MacWorkspace()
        cancel.beginPaneDrag("a")
        cancel.dragPane("a", travel: 160)
        precondition(cancel.paneKeys == ["b", "c", "a", "d"])
        cancel.endPaneDrag("a", cancelled: true)
        precondition(cancel.paneKeys == ["a", "b", "c", "d"] && cancel.synced.isEmpty)
        precondition(cancel.paneShifts["a"] == 160, "drawn where it was, gliding back")

        // Another pane's release cannot end this drag.
        let other = MacWorkspace()
        other.beginPaneDrag("a")
        other.dragPane("a", travel: 120)
        other.endPaneDrag("b")
        precondition(other.paneReorder?.key == "a")
        other.dragPane("b", travel: 120)
        precondition(other.paneKeys == ["b", "a", "c", "d"], "a second drag cannot start mid-drag")

        // The roster changed mid-drag: abandon without restoring or writing.
        let roster = MacWorkspace()
        roster.beginPaneDrag("a")
        roster.dragPane("a", travel: 120)
        roster.paneKeys = ["b", "a", "c"]
        roster.dragPane("a", travel: 220)
        precondition(roster.paneReorder == nil && roster.liftedPane == nil && roster.paneKeys == ["b", "a", "c"])
        roster.dragPane("a", travel: 280)
        roster.endPaneDrag("a")
        precondition(roster.synced.isEmpty && roster.paneKeys == ["b", "a", "c"],
                     "later updates cannot restart an invalidated press")

        // A roster change can land after the final move, just before release.
        for cancelled in [false, true] {
            let release = MacWorkspace()
            release.beginPaneDrag("a")
            release.dragPane("a", travel: 120)
            release.paneKeys.removeAll { $0 == "d" }
            release.endPaneDrag("a", cancelled: cancelled)
            precondition(release.synced.isEmpty && release.paneKeys == ["b", "a", "c"],
                         "release preserves the changed roster without a group write")
            precondition(release.paneReorder == nil && release.liftedPane == nil)
            // Only a new press may start another reorder.
            release.beginPaneDrag("a")
            release.dragPane("a", travel: 150)
            precondition(release.paneReorder?.key == "a")
            release.endPaneDrag("a")
            precondition(release.synced.count == 1)
        }

        let removed = MacWorkspace()
        removed.beginPaneDrag("a")
        removed.dragPane("a", travel: 120)
        removed.paneKeys.removeAll { $0 == "a" }
        removed.endPaneDrag("a")
        precondition(removed.synced.isEmpty && removed.paneReorder == nil && removed.liftedPane == nil)

        // Immediate release at the target slot used to retire the neighbour
        // reset and strand its nonzero drawing offset indefinitely.
        for travel: CGFloat in [100, 100.5, -100, -100.5, 120] {
            let fast = MacWorkspace()
            let key = travel > 0 ? "a" : "d"
            fast.beginPaneDrag(key)
            fast.dragPane(key, travel: travel)
            precondition(!fast.paneShifts.isEmpty, "production neighbour glide is exercised")
            fast.endPaneDrag(key)
            try? await Task.sleep(for: .milliseconds(80))
            precondition(fast.paneShifts.isEmpty && fast.liftedPane == nil && fast.paneReorder == nil,
                         "both pane and neighbour offsets must settle after immediate release")
        }

        MotionEnvironment.reduceMotion = true
        let reduced = MacWorkspace()
        reduced.beginPaneDrag("a")
        reduced.dragPane("a", travel: 120)
        reduced.endPaneDrag("a")
        precondition(reduced.paneShifts.isEmpty && reduced.liftedPane == nil && reduced.paneReorder == nil)
        MotionEnvironment.reduceMotion = false

        // The old landing's completion must not clear a newer landing's
        // raised state when the same pane is dragged twice in quick succession.
        MacMotion.paneGlideSeconds = 0.3
        let repeated = MacWorkspace()
        repeated.beginPaneDrag("a")
        repeated.dragPane("a", travel: 120)
        repeated.endPaneDrag("a")
        try? await Task.sleep(for: .milliseconds(150))
        repeated.beginPaneDrag("a")
        repeated.dragPane("a", travel: 20)
        repeated.endPaneDrag("a")
        try? await Task.sleep(for: .milliseconds(220))
        precondition(repeated.liftedPane == "a", "an earlier landing cannot finish a later landing")
        try? await Task.sleep(for: .milliseconds(150))
        precondition(repeated.liftedPane == nil && repeated.paneShifts.isEmpty)
        MacMotion.paneGlideSeconds = 0

        // No affordance for a single pane, a closing pane or an unmeasured split.
        let single = MacWorkspace()
        single.paneKeys = ["a"]
        single.beginPaneDrag("a")
        single.dragPane("a", travel: 300)
        precondition(single.paneReorder == nil && !single.canReorderPanes)
        let closing = MacWorkspace()
        closing.leavingPanes["x"] = 1
        closing.beginPaneDrag("a")
        closing.dragPane("a", travel: 300)
        precondition(closing.paneReorder == nil && closing.paneKeys == ["a", "b", "c", "d"])
        let unmeasured = MacWorkspace()
        unmeasured.splitWidth = 0
        unmeasured.beginPaneDrag("a")
        unmeasured.dragPane("a", travel: 300)
        precondition(unmeasured.paneReorder == nil)

        // VoiceOver moves: one slot, immediate write, edges ignored.
        let voice = MacWorkspace()
        voice.movePane("a", by: -1)
        precondition(voice.paneKeys == ["a", "b", "c", "d"] && voice.synced.isEmpty)
        voice.movePane("a", by: 1)
        precondition(voice.paneKeys == ["b", "a", "c", "d"] && voice.synced == [["b", "a", "c", "d"]])
        print("PASS: \\(moves) live insertion moves; 4→2; half-cover threshold; edge clamp; cancel restore; "
              + "roster change before update/release; invalidated press; immediate-release motion; "
              + "repeated landings; Reduce Motion; single/closing/unmeasured guards; VoiceOver moves")
    }
}
'''.replace("GEOMETRY", geometry).replace("STATE", state).replace("METHODS", methods).replace("MOTION", motion)
probe = probe.replace("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion", "MotionEnvironment.reduceMotion")
with tempfile.TemporaryDirectory(prefix="corral-pane-reorder-") as directory:
    swift = Path(directory) / "Probe.swift"
    swift.write_text(probe)
    binary = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", str(swift), "-o", binary], check=True)
    subprocess.run([binary], check=True)
