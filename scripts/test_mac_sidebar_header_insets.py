#!/usr/bin/env python3
"""Measure the production date label against native sidebar-row content, without input events."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline-ref", help="Measure an earlier committed header (expected to fail before the fix)")
args = parser.parse_args()
source = (subprocess.check_output(
    ["git", "show", f"{args.baseline_ref}:macOS/Sidebar/MacSidebar.swift"], cwd=ROOT, text=True
) if args.baseline_ref else (ROOT / "macOS/Sidebar/MacSidebar.swift").read_text())
start = source.index("HStack(spacing: Space.sm * interfaceScale)", source.index("Button { toggleSection(section) } label:"))
end_marker = ".contentShape(Rectangle())"
label = source[start:source.index(end_marker, start) + len(end_marker)]
label = label.replace("Text(verbatim: section.items.count.formatted())",
                      'Text(verbatim: section.items.count.formatted()).background(BoundsMarker(name: "count-\\(section.title)"))')
metrics = (ROOT / "macOS/Sidebar/MacSessionRow.swift").read_text()
height = next(line.strip() for line in metrics.splitlines() if "static let sectionHeight:" in line)
with tempfile.TemporaryDirectory(prefix="corral-sidebar-header-") as directory:
    generated = Path(directory) / "ProductionHeader.swift"
    generated.write_text("""import AppKit
import SwiftUI
struct HeaderSection {
    let title: String
    let items: [Int]
}
enum MacSidebarMetrics { """ + height + """ }
struct ProductionHeader: View {
    @Environment(\\.interfaceScale) private var interfaceScale
    let section: HeaderSection
    private func title(for section: HeaderSection) -> String { section.title }
    var body: some View {
""" + label + "\n    }\n}\n")
    sources = [ROOT / path for path in [
        "Shared/UI/Design/InterfaceScale.swift", "Shared/UI/Design/Typography.swift",
        "Shared/UI/Design/SessionTextSize.swift", "Shared/UI/Design/Space.swift",
        "Shared/UI/Platform/PlatformSupport.swift",
        "scripts/mac-sidebar-header-insets/Probe.swift",
    ]]
    binary = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", *map(str, sources), str(generated), "-o", binary], check=True)
    subprocess.run([binary], check=True, timeout=40)
