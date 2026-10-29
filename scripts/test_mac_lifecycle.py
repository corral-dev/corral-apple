#!/usr/bin/env python3
"""Compile actual Mac lifecycle owners against a controllable transport.

No app or user-data fixtures are launched. The Xcode build and real-host
acceptance remain separate checks; these regressions force late completions.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    'Shared/Core/Models/RemoteDecoding.swift',
    'Shared/Core/Models/DesktopLayoutModels.swift',
    'Shared/Core/Store/SessionRestartTracker.swift',
    'Shared/UI/Sessions/FulltextSearchStore.swift',
    'Shared/Core/Presentation/SessionNavigationHistory.swift',
    'macOS/Workspace/MacNavigationState.swift',
    'Shared/UI/Chat/ChatScrollRequest.swift',
    'macOS/Workspace/MacWorkspace.swift',
    'macOS/Sidebar/MacSessionBatch.swift',
    'scripts/mac-lifecycle/SessionBatchProbe.swift',
    'scripts/mac-lifecycle/TerminalRecoveryProbe.swift',
    'macOS/Design/MacMotion.swift',
    'Shared/Core/Terminal/RemoteTerminalStream.swift',
    'Shared/Core/Terminal/ProjectShellStore.swift',
    'scripts/mac-lifecycle/Probe.swift',
]
with tempfile.TemporaryDirectory(prefix='corral-mac-lifecycle-') as directory:
    executable = str(Path(directory) / 'probe')
    # Compile the exact production path helpers without unrelated list models.
    filtering = (ROOT / 'Shared/Core/Presentation/SessionListFiltering.swift').read_text()
    helper = Path(directory) / 'DirectoryIdentity.swift'
    helper.write_text('import Foundation\nenum SessionListFiltering {\n'
                      + filtering[filtering.index('    private static func normalizeDirectory'):])
    pane_source = (ROOT / 'macOS/Panes/MacPaneReordering.swift').read_text()
    pane_helper = Path(directory) / 'MacPaneDragGeometry.swift'
    pane_helper.write_text('import Foundation\n'
                           + pane_source[pane_source.index('nonisolated struct MacPaneDragGeometry'):
                                         pane_source.index("/// The header's leading strip")])
    subprocess.run(['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor',
                    '-parse-as-library', str(helper), str(pane_helper), *[str(ROOT / path) for path in SOURCES],
                    '-o', executable], check=True)
    subprocess.run([executable], check=True)
