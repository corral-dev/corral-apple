#!/usr/bin/env python3
"""Convert the approved notification MP3 masters to Apple-compatible IMA4 CAF.

Requires macOS afconvert. Usage: python3 scripts/notification-sounds/generate.py
Preserves timing, sample rate, channels and gain: no trimming or effects.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCES = Path(__file__).resolve().parent / "sources"
OUT = ROOT / "Shared" / "Resources" / "Sounds"
PRESETS = ("wooden-duet", "water-drop", "electronic-chime")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for name in PRESETS:
        source = SOURCES / f"corral-{name}.mp3"
        target = OUT / f"corral-{name}.caf"
        subprocess.run(
            ["afconvert", str(source), str(target), "-d", "ima4", "-f", "caff"],
            check=True,
        )
        print(target.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
