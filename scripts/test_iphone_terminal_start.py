#!/usr/bin/env python3
"""Mount the production phone terminal with an isolated transport on macOS.

Checks startup/lifecycle without a simulator, pointer events or user sessions.
This is logic evidence, not physical iPhone acceptance.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corral-phone-terminal-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library",
        str(root / "iOS/Views/Terminal/AgentTerminalPane.swift"),
        str(root / "scripts/iphone-terminal-start/Probe.swift"),
        "-o", executable,
    ], check=True)
    subprocess.run([executable], check=True)
