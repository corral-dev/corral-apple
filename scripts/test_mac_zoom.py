#!/usr/bin/env python3
"""Validate production Mac zoom storage, native fonts and mounted layout.

Real menu focus, terminal/host behavior and captures use MacZoomInspection in
an actual Debug client; this offscreen check does not claim screen acceptance.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Shared/Core/Util/AppStorageLocation.swift",
    "Shared/UI/Design/InterfaceScale.swift",
    "macOS/Design/MacInterfaceZoom.swift",
    "macOS/Design/MacZoomScope.swift",
    "scripts/mac-zoom/Probe.swift",
]
with tempfile.TemporaryDirectory(prefix="corral-mac-zoom-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
                    *[str(ROOT / path) for path in SOURCES], "-o", executable], check=True)
    subprocess.run([executable], check=True)
