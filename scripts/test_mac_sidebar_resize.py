#!/usr/bin/env python3
"""Measure production split/chat reflow through a native divider, without input events."""
from pathlib import Path
import argparse
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", required=True)
parser.add_argument("--baseline-ref", help="Compare an existing source revision in the same process")
args = parser.parse_args()
sources = [
    "Shared/UI/Design/InterfaceScale.swift", "Shared/UI/Design/Typography.swift",
    "Shared/UI/Design/SessionTextSize.swift", "Shared/UI/Design/Space.swift",
    "Shared/UI/Platform/PlatformSupport.swift", "Shared/UI/Platform/NativeOverlayScrollers.swift",
    "Shared/Core/Conversation/ChatHistoryPullState.swift", "Shared/UI/Chat/ChatScrollView.swift",
    "Shared/UI/Chat/MacConversationTextDocument.swift", "Shared/UI/Chat/SelectableAttributedText.swift",
    "macOS/Design/MacMotion.swift", "scripts/mac-sidebar-resize/Support.swift",
    "scripts/mac-sidebar-resize/Probe.swift",
]
layout_source = ROOT / "macOS/Panes/EqualPaneLayout.swift"
if layout_source.exists():
    sources.append(str(layout_source))
with tempfile.TemporaryDirectory(prefix="corral-sidebar-resize-") as directory:
    # Compile the actual generic split view without unrelated host services.
    split = (ROOT / "macOS/Panes/MacSplitArea.swift").read_text()
    extracted = Path(directory) / "Split.swift"
    extracted.write_text("import SwiftUI\n" + split[split.index("extension ContainerValues {"):])
    additional = []
    if args.baseline_ref:
        before = subprocess.check_output(["git", "show", f"{args.baseline_ref}:macOS/Panes/MacSplitArea.swift"], cwd=ROOT, text=True)
        baseline = Path(directory) / "BaselineSplit.swift"
        baseline.write_text("import SwiftUI\n" + before[before.index("struct EqualPanes<"):]
                            .replace("EqualPanes", "BaselineEqualPanes").replace("PaneSlot", "BaselinePaneSlot"))
        additional = ["-D", "RESIZE_BASELINE", str(baseline)]
    executable = Path(directory) / "probe"
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", *[str(ROOT / source) for source in sources],
                    str(extracted), *additional, "-o", str(executable)], check=True)
    subprocess.run([str(executable), args.output], check=True)
