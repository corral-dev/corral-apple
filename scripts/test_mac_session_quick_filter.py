#!/usr/bin/env python3
"""Compile the Mac quick-filter state against the actual portable Core sources."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
# The chip resolves an enum-provided key dynamically, outside the literal-Text
# scan in check_localizations.py; both mode labels must exist in the catalog.
CATALOG = json.loads((ROOT / "Shared/Resources/Localizable.xcstrings").read_text())["strings"]
for key in ("sessions.filter.attention", "sessions.filter.active"):
    for language in ("en", "zh-Hans"):
        unit = CATALOG[key]["localizations"][language]["stringUnit"]
        if unit["state"] != "translated" or not unit["value"].strip():
            raise AssertionError(f"Missing translated quick-filter label: {key}/{language}")
print("PASS dynamic quick-filter labels in English and Simplified Chinese", flush=True)

PROBE = r'''
import Foundation

@main struct Probe {
    @MainActor static func main() {
        let sessions = [
            SessionSummary(key: "claude:working", runtime: "claude", cwd: "/work/one", attention: .working, marker: "working", needsAttention: true),
            SessionSummary(key: "codex:waiting", runtime: "codex", cwd: "/work/two", attention: .waiting, marker: "waiting", needsAttention: true),
            SessionSummary(key: "pi:recent", runtime: "pi", cwd: "/work/one", marker: "recent", needsAttention: true),
            SessionSummary(key: "codex:unread", runtime: "codex", cwd: "/work/one", attention: .unread, marker: "unread", needsAttention: true),
            SessionSummary(key: "pi:opened", runtime: "pi", cwd: "/work/one", marker: "", needsAttention: true),
            SessionSummary(key: "cursor:idle", runtime: "cursor", cwd: "/work/one", live: true, marker: "", needsAttention: false),
            SessionSummary(key: "claude:dual", runtime: "claude", cwd: "/work/one", attention: .working, marker: "unread", needsAttention: true),
            SessionSummary(key: "kimi:dormant", runtime: "kimi", attention: .working, marker: "working", needsAttention: true),
        ]
        var mode = SessionQuickFilter.all
        for cycle in 0..<3 {
            precondition(mode == .all)
            precondition(mode.titleKey == "sessions.filter.attention")
            precondition(mode.apply(sessions: sessions).count == 7)
            precondition(mode.count(sessions: sessions) == 6)
            mode.advance()
            precondition(mode == .attention)
            precondition(mode.apply(sessions: sessions).map(\.key) == [
                "claude:working", "codex:waiting", "pi:recent", "codex:unread", "pi:opened", "claude:dual",
            ])
            precondition(mode.count(sessions: sessions) == 6)
            mode.advance()
            precondition(mode == .active)
            precondition(mode.titleKey == "sessions.filter.active")
            precondition(mode.apply(sessions: sessions).map(\.key) == [
                "claude:working", "codex:waiting", "pi:recent", "claude:dual",
            ])
            precondition(mode.count(sessions: sessions) == 4)
            mode.advance()
            precondition(mode == .all)
            print("PASS full three-click cycle \(cycle + 1)")
        }
        for mode in SessionQuickFilter.allCases {
            let narrowed = mode.apply(sessions: sessions, runtimes: [.claude], projects: [.project(path: "/work/one")])
            precondition(narrowed.map(\.key) == ["claude:working", "claude:dual"])
            precondition(mode.apply(sessions: [], runtimes: [], projects: []).isEmpty)
            precondition(mode.count(sessions: []) == 0)
        }
        precondition(SessionQuickFilter.active.apply(sessions: [sessions[3]]).isEmpty)
        precondition(!SessionQuickFilter.attention.apply(sessions: [sessions[3]]).isEmpty)
        print("PASS Focus/Active membership, independent counts, intersections, empty states, dormant exclusion and unread/activity independence")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="corral-mac-quick-filter-") as directory:
    source = Path(directory) / "Probe.swift"
    source.write_text(PROBE)
    binary = Path(directory) / "probe"
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
        *map(str, sorted((ROOT / "Shared/Core").rglob("*.swift"))),
        str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
