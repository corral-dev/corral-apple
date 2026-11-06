#!/usr/bin/env python3
"""Render the production identity decoration at phone/split/desktop sizes.

No application, user session, display or pointer is driven. Physical-device and
installed-window acceptance remain separate from these native raster checks.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='corral-session-identity-') as directory:
    source = (ROOT / 'Shared/Core/Presentation/SessionPresentation.swift').read_text()
    start = source.index('    static func titleIcon(')
    end = source.index('\n    ///', start)
    helper = Path(directory) / 'SessionPresentation.swift'
    helper.write_text('import Foundation\nenum SessionPresentation {\n' + source[start:end] + '\n}\n')
    executable = str(Path(directory) / 'probe')
    sources = [
        'Shared/UI/Design/Space.swift',
        'Shared/UI/Design/InterfaceScale.swift',
        'Shared/UI/Design/SessionIdentityBackground.swift',
        'scripts/session-identity/Probe.swift',
    ]
    subprocess.run(['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-parse-as-library', str(helper), *[str(ROOT / path) for path in sources],
                    '-o', executable], check=True)
    subprocess.run([executable], check=True)
