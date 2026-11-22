#!/usr/bin/env python3
"""Mount production MacSidebarFilters across widths/scales and verify 6-runtime fit."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

session_row_text = (ROOT / "macOS/Sidebar/MacSessionRow.swift").read_text()
filter_height = next(line.strip() for line in session_row_text.splitlines() if "static let filterHeight:" in line)
sidebar_filter_height = next(line.strip() for line in session_row_text.splitlines() if "static let sidebarFilterHeight:" in line)

catalog = json.loads((ROOT / "Shared/Resources/Localizable.xcstrings").read_text())["strings"]

def write_strings_file(dest: Path, lang: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    lines = []
    for key, entry in catalog.items():
        val = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {}).get("value")
        if val is not None:
            escaped_key = key.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            escaped_val = val.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            lines.append(f'"{escaped_key}" = "{escaped_val}";')
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")

PROBE_SWIFT = f'''
import AppKit
import SwiftUI

enum MacSidebarMetrics {{
    {filter_height}
    {sidebar_filter_height}
}}

struct RuntimeBoundsMarker: NSViewRepresentable {{
    static var views: [String: NSView] = [:]
    let id: String
    func makeNSView(context: Context) -> NSView {{
        let v = NSView()
        Self.views[id] = v
        return v
    }}
    func updateNSView(_ v: NSView, context: Context) {{
        Self.views[id] = v
    }}
}}

private struct FilterHostView: View {{
    let sessions: [SessionSummary]
    @State var quickFilter: SessionQuickFilter
    @State var runtimes: Set<SessionRuntimeFilter>
    @State var projects: Set<SessionProjectFilter>
    let sidebarWidth: CGFloat
    let scale: CGFloat
    let onMeasure: (CGFloat) -> Void

    var body: some View {{
        MacSidebarFilters(
            sessions: sessions,
            quickFilter: $quickFilter,
            runtimes: $runtimes,
            projects: $projects
        )
        .interfacePadding(.horizontal, Space.md)
        .interfacePadding(.vertical, 6)
        .frame(width: sidebarWidth, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) {{ $0.size.height }} action: {{ totalH in
            onMeasure(totalH)
        }}
        .environment(\\.interfaceScale, scale)
        .environment(\\.controlActiveState, .key)
    }}
}}

private func findScrollViews(in view: NSView) -> [NSScrollView] {{
    var result: [NSScrollView] = []
    if let sv = view as? NSScrollView {{ result.append(sv) }}
    for sub in view.subviews {{ result.append(contentsOf: findScrollViews(in: sub)) }}
    return result
}}

@main
struct Probe {{
    static func main() throws {{
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()

        let sessions: [SessionSummary] = [
            SessionSummary(key: "claude:1", runtime: "claude", cwd: "/tmp/NeatMark", attention: .waiting, marker: "waiting", needsAttention: true),
            SessionSummary(key: "codex:1", runtime: "codex", cwd: "/tmp/Forenote", attention: .working, marker: "working", needsAttention: true),
            SessionSummary(key: "opencode:1", runtime: "opencode", cwd: "/tmp/LanVNC", attention: .unread, marker: "unread", needsAttention: true),
            SessionSummary(key: "cursor:1", runtime: "cursor", cwd: "/tmp/Codes", needsAttention: false),
            SessionSummary(key: "pi:1", runtime: "pi", cwd: "/tmp/Corral", needsAttention: true),
            SessionSummary(key: "antigravity:1", runtime: "antigravity", cwd: "/tmp/LanVNC", attention: .working, marker: "working", needsAttention: true),
        ] + (0..<10).map {{ i in
            SessionSummary(key: "claude:extra\\(i)", runtime: "claude", cwd: "/tmp/NeatMark", attention: .waiting, marker: "waiting", needsAttention: true)
        }}

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 460, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {{ window.close() }}

        struct Case {{
            let name: String
            let width: CGFloat
            let scale: CGFloat
            let quick: SessionQuickFilter
            let runtimes: Set<SessionRuntimeFilter>
            let expectEdgeFill: Bool
            let expectFits: Bool
        }}

        let cases: [Case] = [
            Case(name: "min-260-unfiltered-100", width: 260, scale: 1.0, quick: .all, runtimes: [], expectEdgeFill: true, expectFits: true),
            Case(name: "min-260-active-all6-100", width: 260, scale: 1.0, quick: .active, runtimes: Set(SessionRuntimeFilter.ordered.filter {{ $0 != .all }}), expectEdgeFill: true, expectFits: true),
            Case(name: "live-272-focus-antigravity-100", width: 272, scale: 1.0, quick: .attention, runtimes: [.antigravity], expectEdgeFill: true, expectFits: true),
            Case(name: "ideal-310-active-all6-100", width: 310, scale: 1.0, quick: .active, runtimes: Set(SessionRuntimeFilter.ordered.filter {{ $0 != .all }}), expectEdgeFill: true, expectFits: true),
            Case(name: "wide-360-active-all6-100", width: 360, scale: 1.0, quick: .active, runtimes: Set(SessionRuntimeFilter.ordered.filter {{ $0 != .all }}), expectEdgeFill: true, expectFits: true),
            Case(name: "max-440-active-all6-100", width: 440, scale: 1.0, quick: .active, runtimes: Set(SessionRuntimeFilter.ordered.filter {{ $0 != .all }}), expectEdgeFill: false, expectFits: true),
            Case(name: "ideal-465-active-all6-150", width: 465, scale: 1.5, quick: .active, runtimes: Set(SessionRuntimeFilter.ordered.filter {{ $0 != .all }}), expectEdgeFill: true, expectFits: true),
            Case(name: "ideal-248-active-all6-80", width: 248, scale: 0.8, quick: .active, runtimes: Set(SessionRuntimeFilter.ordered.filter {{ $0 != .all }}), expectEdgeFill: false, expectFits: false),
        ]

        var results: [[String: Any]] = []
        var failures: [String] = []
        var unselectedWidths: [String: CGFloat] = [:]
        var selectedWidths: [String: CGFloat] = [:]
        var runtimeGapsByCase: [String: CGFloat] = [:]

        for c in cases {{
            RuntimeBoundsMarker.views = [:]
            var measuredHeight: CGFloat = 0
            window.setContentSize(NSSize(width: c.width + 20, height: 160))
            let host = NSHostingView(rootView: FilterHostView(
                sessions: sessions,
                quickFilter: c.quick,
                runtimes: c.runtimes,
                projects: [],
                sidebarWidth: c.width,
                scale: c.scale
            ) {{ totalH in measuredHeight = totalH }})
            window.contentView = host
            window.orderBack(nil)
            for _ in 0..<15 {{
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.layoutSubtreeIfNeeded()
            }}

            let scrollViews = findScrollViews(in: host)
            guard let row1 = scrollViews.first,
                  let doc = row1.documentView else {{
                failures.append("\\(c.name): missing row1 NSScrollView")
                continue
            }}
            let contentWidth = doc.frame.width
            let viewportWidth = row1.contentView.bounds.width
            let fits = contentWidth <= viewportWidth + 0.5
            if c.expectFits && !fits {{
                failures.append("\\(c.name): row1 overflows content=\\(contentWidth) > viewport=\\(viewportWidth)")
            }}
            if c.scale == 1.0 && measuredHeight > 76.0 {{
                failures.append("\\(c.name): height=\\(measuredHeight) exceeds 76pt")
            }}
            let mounted = RuntimeBoundsMarker.views.filter {{ $0.value.window === window }}
            if mounted.count != 6 {{
                failures.append("\\(c.name): expected 6 runtime bounds markers, got \\(mounted.count)")
            }}
            for (id, view) in mounted {{
                let w = view.bounds.width
                if c.name == "min-260-unfiltered-100" {{
                    unselectedWidths[id] = w
                }} else if c.name == "min-260-active-all6-100" {{
                    selectedWidths[id] = w
                }}
            }}
            let orderedFrames = mounted.values
                .map {{ $0.convert($0.bounds, to: row1.contentView) }}
                .sorted {{ $0.minX < $1.minX }}
            let gaps = zip(orderedFrames, orderedFrames.dropFirst()).map {{ $1.minX - $0.maxX }}
            let widths = orderedFrames.map(\.width)
            let avgGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / CGFloat(gaps.count)
            let avgWidth = widths.isEmpty ? 0 : widths.reduce(0, +) / CGFloat(widths.count)
            let trailingGap = orderedFrames.last.map {{ viewportWidth - $0.maxX }} ?? viewportWidth
            if let maxG = gaps.max(), let minG = gaps.min(), maxG - minG > 1.5 {{
                failures.append("\\(c.name): unequal runtime gaps \\(gaps)")
            }}
            if let maxW = widths.max(), let minW = widths.min(), maxW - minW > 1.5 {{
                failures.append("\\(c.name): unequal runtime button widths \\(widths)")
            }}
            if avgWidth < 23.0 * c.scale - 0.5 || avgWidth > 42.0 * c.scale + 0.5 {{
                failures.append("\\(c.name): runtime button width \\(avgWidth) outside bounds [\\(23.0 * c.scale), \\(42.0 * c.scale)]")
            }}
            if c.expectEdgeFill && abs(trailingGap) > 2.5 {{
                failures.append("\\(c.name): trailing edge gap \\(trailingGap) exceeds 2.5pt (not edge-aligned)")
            }}
            runtimeGapsByCase[c.name] = avgWidth
            results.append([
                "name": c.name,
                "sidebarWidth": c.width,
                "scale": c.scale,
                "row1ContentWidth": contentWidth,
                "row1ViewportWidth": viewportWidth,
                "avgRuntimeGap": avgGap,
                "avgRuntimeWidth": avgWidth,
                "trailingGap": trailingGap,
                "fits": fits,
                "totalHeight": measuredHeight,
                "runtimeCount": mounted.count,
            ])
        }}

        if let minW = runtimeGapsByCase["live-272-focus-antigravity-100"],
           let idealW = runtimeGapsByCase["ideal-310-active-all6-100"],
           let wideW = runtimeGapsByCase["wide-360-active-all6-100"],
           let maxW = runtimeGapsByCase["max-440-active-all6-100"] {{
            if !(idealW > minW + 5.0 && wideW > idealW + 6.0 && maxW >= 41.5 && maxW <= 42.5) {{
                failures.append("Adaptive bounded width failed: live272=\\(minW) ideal310=\\(idealW) wide360=\\(wideW) max440=\\(maxW)")
            }}
        }}

        for (id, uw) in unselectedWidths {{
            if let sw = selectedWidths[id], abs(uw - sw) > 0.5 {{
                failures.append("Runtime \\(id) shifted width on selection: unselected=\\(uw) selected=\\(sw)")
            }}
        }}

        let report: [String: Any] = [
            "results": results,
            "failures": failures,
            "passed": failures.isEmpty && results.count == cases.count,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !failures.isEmpty || results.count != cases.count {{
            exit(1)
        }}
    }}
}}
'''

with tempfile.TemporaryDirectory(prefix="corral-sidebar-filters-") as directory:
    tmp = Path(directory)
    app_dir = tmp / "Probe.app/Contents"
    macos_dir = app_dir / "MacOS"
    res_dir = app_dir / "Resources"
    macos_dir.mkdir(parents=True)
    (app_dir / "Info.plist").write_text(r"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.x0c.corral.probe</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
</dict></plist>
""")
    write_strings_file(res_dir / "en.lproj/Localizable.strings", "en")
    write_strings_file(res_dir / "zh-Hans.lproj/Localizable.strings", "zh-Hans")

    filters_copy = tmp / "MacSidebarFilters.swift"
    filters_src = (ROOT / "macOS/Sidebar/MacSidebarFilters.swift").read_text()
    target_line = '.accessibilityIdentifier("corral.filter.runtime." + runtime.rawValue)'
    assert target_line in filters_src
    filters_copy.write_text(filters_src.replace(
        target_line,
        target_line + '\n                    .background(RuntimeBoundsMarker(id: runtime.rawValue))'
    ))

    probe_file = tmp / "Probe.swift"
    probe_file.write_text(PROBE_SWIFT)
    sources = [
        *sorted((ROOT / "Shared/Core").rglob("*.swift")),
        ROOT / "Shared/UI/Design/InterfaceScale.swift",
        ROOT / "Shared/UI/Design/Space.swift",
        ROOT / "Shared/UI/Design/Palette.swift",
        ROOT / "Shared/UI/Platform/PlatformSupport.swift",
        ROOT / "Shared/UI/Platform/InspectionLaunchOptions.swift",
        ROOT / "Shared/UI/Sessions/AdaptiveFilterRowLayout.swift",
        ROOT / "Shared/UI/Sessions/ProjectFilterSummaryLabel.swift",
        ROOT / "Shared/UI/Sessions/NewSessionPickers.swift",
        filters_copy,
        probe_file,
    ]
    binary = macos_dir / "probe"
    subprocess.run([
        "swiftc", "-D", "DEBUG", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", *map(str, sources), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary), "-AppleLanguages", "(en)"], check=True, timeout=40)
    subprocess.run([str(binary), "-AppleLanguages", "(zh-Hans)"], check=True, timeout=40)
