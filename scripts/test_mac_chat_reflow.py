#!/usr/bin/env python3
"""Mount production chat/selection/tool controls; inspect native hits and reflow.

No pointer events, keyboard events, real session data or preferences are used.
This validates native geometry and text layout, not physical macOS 26 clicks or
WindowServer rendering while the console is locked.
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
    "Shared/Core/Conversation/ChatHistoryPullState.swift", "Shared/UI/Chat/ChatScrollView.swift",
    "Shared/UI/Chat/MacConversationTextDocument.swift", "Shared/UI/Chat/SelectableAttributedText.swift",
    "Shared/UI/Chat/ToolActivityView.swift", "scripts/mac-chat-reflow/Support.swift",
    "scripts/mac-chat-reflow/Probe.swift",
]
with tempfile.TemporaryDirectory(prefix="corral-mac-chat-reflow-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
                    *[str(ROOT / path) for path in SOURCES], "-o", executable], check=True)
    subprocess.run([executable, *sys.argv[1:]], check=True)
