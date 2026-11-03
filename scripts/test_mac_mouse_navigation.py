#!/usr/bin/env python3
"""Exercise production mouse navigation with native in-process AppKit events."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corral-mac-mouse-navigation-") as directory:
    binary = str(Path(directory) / "probe")
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", str(ROOT / "macOS/Workspace/MacMouseNavigation.swift"),
        str(ROOT / "Shared/Core/Presentation/SessionNavigationHistory.swift"),
        str(ROOT / "scripts/mac-mouse-navigation/Probe.swift"), "-o", binary,
    ], check=True)
    subprocess.run([binary], check=True)
