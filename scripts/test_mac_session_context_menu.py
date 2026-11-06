#!/usr/bin/env python3
"""Query production native context menus without posting pointer events."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
products = ROOT / '.derivedData-mac/Build/Products/Debug'
with tempfile.TemporaryDirectory(prefix='corral-context-menu-') as directory:
    executable = str(Path(directory) / 'probe')
    # StreamTerminalView's live IME cursor now uses the production cell metric.
    # Compile those exact helpers without the unrelated emulator/transport shell.
    appearance = (ROOT / 'macOS/Terminal/TerminalEmulatorView.swift').read_text()
    metric = appearance[appearance.index('    static func cellSize('):
                        appearance.index('    static func widthFittingFontSize(')]
    font = appearance[appearance.index('    static func font(size:'):
                      appearance.index('    /// Pane background around the emulator')]
    helper = Path(directory) / 'TerminalAppearance.swift'
    helper.write_text('import AppKit\nimport CoreText\nenum TerminalAppearance {\n'
                      + metric + font + '}\n')
    sources = [
        'Shared/UI/Platform/MacSessionContextMenu.swift',
        'Shared/UI/Chat/MacConversationTextDocument.swift',
        'Shared/UI/Terminal/TerminalHostFeed.swift',
        'macOS/Terminal/StreamTerminalView.swift',
        'scripts/mac-context-menu/Probe.swift',
    ]
    subprocess.run(['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-parse-as-library', '-I', str(products), str(helper),
                    *[str(ROOT / source) for source in sources],
                    str(products / 'SwiftTerm.o'), '-o', executable], check=True)
    subprocess.run([executable], check=True)
