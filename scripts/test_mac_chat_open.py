#!/usr/bin/env python3
"""Mount the production chat scroll view; verify opening never leaves a blank viewport.

Covers the first window, live append, wholesale window replacement and older-page
prepend while following the latest message, in visible and revealed-dormant hosts.
No pointer events, real session data or preferences are used. This validates
native layout and row realization, not WindowServer pixels while the console is locked.
"""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Shared/UI/Design/InterfaceScale.swift", "Shared/UI/Design/Typography.swift",
    "Shared/UI/Design/SessionTextSize.swift", "Shared/UI/Design/Space.swift",
    "Shared/UI/Platform/PlatformSupport.swift", "Shared/UI/Platform/NativeOverlayScrollers.swift",
    "Shared/UI/Platform/MacSessionContextMenu.swift",
    "Shared/Core/Conversation/ChatHistoryPullState.swift", "Shared/UI/Chat/ChatScrollView.swift",
    "Shared/UI/Chat/MacConversationTextDocument.swift", "Shared/UI/Chat/SelectableAttributedText.swift",
    "Shared/Core/Conversation/ChatDiagramBlock.swift",
    "Shared/UI/Chat/ChatMarkdown.swift", "Shared/UI/Chat/MacMarkdownTable.swift",
    "Shared/UI/Chat/ToolActivityView.swift", "scripts/mac-chat-reflow/Support.swift",
    "scripts/mac-chat-open/Probe.swift",
]
with tempfile.TemporaryDirectory(prefix="corral-mac-chat-open-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library", "-DCORRAL_REAL_MARKDOWN",
                    *[str(ROOT / path) for path in SOURCES], "-o", executable], check=True)
    subprocess.run([executable, *sys.argv[1:]], check=True)
