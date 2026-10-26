#!/usr/bin/env python3
"""Exercise the production native pane cache, lease and suspension ownership."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corral-mac-session-switch-") as directory:
    binary = str(Path(directory) / "probe")
    split = (ROOT / "macOS/Panes/MacSplitArea.swift").read_text()
    start = split.index("nonisolated private struct MacRetainedPaneKey")
    end = split.index("/// Minimum window width requested", start)
    combined = Path(directory) / "MountedProbe.swift"
    combined.write_text((ROOT / "scripts/mac-session-switch/Probe.swift").read_text()
                        + split[start:end]
                        + (ROOT / "scripts/mac-session-switch/LayoutProbe.swift").read_text())
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-DDEBUG", "-parse-as-library", str(ROOT / "macOS/Panes/MacPaneSurface.swift"),
        str(ROOT / "macOS/Panes/EqualPaneLayout.swift"),
        str(ROOT / "Shared/UI/Chat/MacConversationTextDocument.swift"),
        str(ROOT / "Shared/UI/Platform/MacSessionContextMenu.swift"),
        str(combined), "-o", binary,
    ], check=True)
    subprocess.run([binary], check=True)
