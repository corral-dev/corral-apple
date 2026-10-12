#!/usr/bin/env python3
"""Mount native scroll containers; never drive the pointer or change preferences."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corral-mac-scrollbars-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
        str(ROOT / "Shared/UI/Platform/NativeOverlayScrollers.swift"),
        str(ROOT / "macOS/Sidebar/NativeSidebarSelection.swift"),
        str(ROOT / "macOS/Design/MacScrollerPreference.swift"),
        str(ROOT / "scripts/mac-scrollbars/Probe.swift"), "-o", executable,
    ], check=True)
    subprocess.run([executable], check=True)
    # Process-local argument domain: the legacy preference of the reported
    # macOS 26 abort, without writing any user preference.
    subprocess.run([executable, "-AppleShowScrollBars", "Always"], check=True)
    # The app's process-only preference must win over that legacy setting so
    # SwiftUI List chooses thin overlay scrollers itself.
    subprocess.run([executable, "-AppleShowScrollBars", "Always", "-CorralProbeScrollerPreference"], check=True)
