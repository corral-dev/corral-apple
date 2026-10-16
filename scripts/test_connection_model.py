#!/usr/bin/env python3
"""Exercise the real AppModel and core on macOS without UI driving or pairing mutations."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
sources = sorted((root / 'Shared/Core').rglob('*.swift'))
sources += [root / 'Shared/UI/AppModel.swift', root / 'Shared/UI/Design/AppPreferences.swift',
            root / 'scripts/connection-recovery/ModelProbe.swift']
with tempfile.TemporaryDirectory(prefix='corral-connection-model-') as directory:
    binary = str(Path(directory) / 'probe')
    subprocess.run(['swiftc', '-D', 'DEBUG', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-parse-as-library', *map(str, sources), '-o', binary], check=True)
    subprocess.run([binary], check=True)
