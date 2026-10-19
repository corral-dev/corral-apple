#!/usr/bin/env python3
"""Generate Corral's original notification sound presets.

Writes `Shared/Resources/Sounds/corral-<preset>.caf` (IMA4 CAF, 44.1 kHz mono)
from pure synthesis so the assets are reproducible and license-free.
Requires macOS `afconvert`. Usage: python3 scripts/notification-sounds/generate.py
"""
from __future__ import annotations

import math
import struct
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

RATE = 44_100
OUT = Path(__file__).resolve().parents[2] / "Shared" / "Resources" / "Sounds"


def note(freq: float, start: float, length: float, partials: list[tuple[float, float, float]],
         attack: float = 0.004) -> tuple[float, list[float]]:
    """One struck note; each partial is (frequency ratio, amplitude, decay rate)."""
    count = int(length * RATE)
    samples = []
    for i in range(count):
        t = i / RATE
        env = min(1.0, t / attack)
        value = sum(amp * math.exp(-decay * t) * math.sin(2 * math.pi * freq * ratio * t)
                    for ratio, amp, decay in partials)
        samples.append(env * value)
    return start, samples


def mix(notes: list[tuple[float, list[float]]], tail: float = 0.05) -> list[float]:
    length = max(int(start * RATE) + len(s) for start, s in notes) + int(tail * RATE)
    out = [0.0] * length
    for start, samples in notes:
        offset = int(start * RATE)
        for i, value in enumerate(samples):
            out[offset + i] += value
    peak = max(abs(v) for v in out) or 1.0
    # Normalize to -3 dBFS and fade the last 30 ms so no preset clicks.
    fade = int(0.03 * RATE)
    for i in range(length):
        gain = 0.707 / peak
        if i >= length - fade:
            gain *= (length - i) / fade
        out[i] *= gain
    return out


# Bell: inharmonic upper partials give a glassy ring.
BELL = [(1.0, 1.0, 4.0), (2.76, 0.35, 7.0), (5.40, 0.12, 12.0)]
# Marimba: bar tuning (1x, 4x, 10x) with a fast-decaying wooden top.
MARIMBA = [(1.0, 1.0, 6.0), (3.93, 0.30, 22.0), (9.80, 0.06, 40.0)]
# Soft tap: nearly pure, low and short.
TAP = [(1.0, 1.0, 14.0), (2.0, 0.18, 30.0)]

PRESETS = {
    # Two-note rising chime: E6 then B6.
    "chime": [note(1318.5, 0.0, 0.9, BELL), note(1975.5, 0.12, 1.0, BELL)],
    # Quick major arpeggio: C5, E5, G5.
    "marimba": [note(523.3, 0.0, 0.5, MARIMBA), note(659.3, 0.09, 0.5, MARIMBA),
                note(784.0, 0.18, 0.7, MARIMBA)],
    # Two gentle low knocks: A4, A4.
    "tap": [note(440.0, 0.0, 0.35, TAP, attack=0.006), note(440.0, 0.16, 0.4, TAP, attack=0.006)],
}


def write(name: str, samples: list[float]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    target = OUT / f"corral-{name}.caf"
    with tempfile.TemporaryDirectory() as tmp:
        wav = Path(tmp) / f"{name}.wav"
        with wave.open(str(wav), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(RATE)
            handle.writeframes(b"".join(struct.pack("<h", int(v * 32767)) for v in samples))
        subprocess.run(["afconvert", "-f", "caff", "-d", "ima4", str(wav), str(target)], check=True)
    print(f"{target.relative_to(OUT.parents[2])}: {len(samples) / RATE:.2f}s")


def main() -> int:
    for name, notes in PRESETS.items():
        write(name, mix(notes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
