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
        str(ROOT / "scripts/mac-scrollbars/Probe.swift"), "-o", executable,
    ], check=True)
    subprocess.run([executable], check=True)
