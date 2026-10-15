#!/usr/bin/env python3
"""Exercise the shared calendar owner with real native notifications and an isolated clock."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = sorted((root / "Shared/Core").rglob("*.swift"))
sources += [root / "Shared/UI/AppModel.swift", root / "Shared/UI/Sessions/HostSessionFeed.swift",
            root / "scripts/session-calendar/Probe.swift"]
with tempfile.TemporaryDirectory(prefix="corral-session-calendar-") as directory:
    binary = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-D", "DEBUG", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", *map(str, sources), "-o", binary], check=True)
    subprocess.run([binary], check=True, timeout=30)
