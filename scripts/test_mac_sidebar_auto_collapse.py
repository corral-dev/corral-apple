#!/usr/bin/env python3
"""Check the production Mac sidebar fit rules (thresholds, hysteresis, manual choice)."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = r'''
import Foundation

var failures: [String] = []
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

for (panes, minimum) in [(1, 520.0), (2, 520.0), (3, 662.0), (4, 883.0)] {
    let value = MacSidebarSizing.minimumWindowWidth(panes: panes)
    expect(value == minimum, "minimum for \(panes) panes: \(value), expected \(minimum)")
}
for (panes, collapse) in [(1, 570.0), (2, 791.0), (3, 1012.0), (4, 1233.0)] {
    let value = MacSidebarSizing.collapseWidth(panes: panes, sidebarWidth: 310)
    expect(value == collapse, "collapse for \(panes) panes: \(value), expected \(collapse)")
}
expect(MacSidebarSizing.expandWidth(panes: 1, sidebarWidth: 310) == 650,
       "expand must add the 80 pt hysteresis")

func next(_ collapsed: Bool, hidden: Bool = false, _ width: CGFloat,
          from previous: CGFloat?, collapse: CGFloat = 570, expand: CGFloat = 650) -> Bool {
    MacSidebarSizing.nextAutoCollapse(currentlyCollapsed: collapsed, manuallyHidden: hidden,
                                      width: width, previousWidth: previous,
                                      collapseAt: collapse, expandAt: expand)
}

expect(next(false, 560, from: 600), "downward crossing must collapse")
expect(!next(false, 550, from: 560), "no crossing must leave a manually shown sidebar alone")
expect(next(false, 560, from: nil), "first narrow measurement must collapse")
expect(!next(false, 600, from: nil), "first wide measurement must stay expanded")
expect(!next(true, 660, from: 640), "widening past the expand point must restore the sidebar")
expect(next(true, 655, from: 660), "inside the hysteresis band the sidebar stays collapsed")
expect(!next(true, 660, from: nil), "a restored collapsed sidebar reopens on a wide first measurement")
expect(next(true, 600, from: nil), "a restored collapsed sidebar stays closed on a narrow first measurement")
expect(!next(false, hidden: true, 400, from: 800), "a manual hide is never auto-collapsed or reopened")

expect(!MacSidebarSizing.fitAfterLayoutChange(currentlyCollapsed: false, manuallyHidden: false,
                                             width: 800, collapseAt: 791, expandAt: 871),
       "a pane change that still fits keeps the sidebar")
expect(MacSidebarSizing.fitAfterLayoutChange(currentlyCollapsed: false, manuallyHidden: false,
                                            width: 780, collapseAt: 791, expandAt: 871),
       "a pane change below the fit width collapses the sidebar")
expect(!MacSidebarSizing.fitAfterLayoutChange(currentlyCollapsed: true, manuallyHidden: false,
                                             width: 900, collapseAt: 791, expandAt: 871),
       "closing panes can restore an automatically collapsed sidebar")
expect(MacSidebarSizing.fitAfterLayoutChange(currentlyCollapsed: true, manuallyHidden: false,
                                            width: 800, collapseAt: 791, expandAt: 871),
       "inside the hysteresis band the sidebar stays collapsed after a pane change")
expect(!MacSidebarSizing.fitAfterLayoutChange(currentlyCollapsed: false, manuallyHidden: true,
                                             width: 500, collapseAt: 570, expandAt: 650),
       "a manual hide survives pane changes")

if failures.isEmpty {
    print("sidebar fit: all checks pass")
} else {
    for failure in failures { FileHandle.standardError.write(Data(("FAIL: " + failure + "\n").utf8)) }
    exit(1)
}
'''

with tempfile.TemporaryDirectory(prefix="corral-mac-sidebar-fit-") as directory:
    source = Path(directory) / "main.swift"
    source.write_text(PROBE)
    binary = Path(directory) / "probe"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        str(ROOT / "macOS/Sidebar/MacSidebarSizing.swift"),
        str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
