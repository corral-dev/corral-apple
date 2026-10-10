#!/usr/bin/env python3
"""Exercise production AppKit text networks without driving pointer/keyboard UI."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corral-mac-text-selection-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
        str(ROOT / "Shared/UI/Chat/MacConversationTextDocument.swift"),
        str(ROOT / "scripts/mac-lifecycle/TextSelectionProbe.swift"), "-o", executable,
    ], check=True)
    subprocess.run([executable], check=True)
