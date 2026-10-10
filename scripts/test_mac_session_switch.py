#!/usr/bin/env python3
"""Exercise the production native pane cache, lease and suspension ownership."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corral-mac-session-switch-") as directory:
    binary = str(Path(directory) / "probe")
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-DDEBUG", "-parse-as-library", str(ROOT / "macOS/Panes/MacPaneSurface.swift"),
        str(ROOT / "scripts/mac-session-switch/Probe.swift"), "-o", binary,
    ], check=True)
    subprocess.run([binary], check=True)
