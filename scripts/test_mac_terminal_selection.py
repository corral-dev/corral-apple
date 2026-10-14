#!/usr/bin/env python3
"""Check the production terminal against the pinned native SwiftTerm build.

Requires a CorralMac Debug build; no pointer events or user sessions are driven.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path, default=ROOT / ".derivedData-mac")
parser.add_argument("--pi-output", type=Path, help="Private JSON array of base64 chunks captured from a disposable Pi TUI")
args = parser.parse_args()
products = args.derived_data.resolve() / "Build/Products/Debug"
module = products / "SwiftTerm.swiftmodule"
library = products / "SwiftTerm.o"
if not module.is_dir() or not library.is_file():
    parser.error("Build CorralMac Debug in the selected derived-data directory first")

with tempfile.TemporaryDirectory(prefix="corral-mac-terminal-selection-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", "-I", str(products),
        str(ROOT / "Shared/UI/Terminal/TerminalHostFeed.swift"),
        str(ROOT / "macOS/Terminal/StreamTerminalView.swift"),
        str(ROOT / "scripts/mac-terminal-selection/Probe.swift"),
        str(library), "-o", executable,
    ], check=True)
    subprocess.run([executable, *([str(args.pi_output)] if args.pi_output else [])], check=True)
