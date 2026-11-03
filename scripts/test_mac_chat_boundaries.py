#!/usr/bin/env python3
"""Mount the production Mac conversation table and verify boundary-aware row caches.

Uses synthetic messages and no pointer input, preferences or user history.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Shared/UI/Design/InterfaceScale.swift", "Shared/UI/Design/Typography.swift",
    "Shared/UI/Design/SessionTextSize.swift", "Shared/UI/Design/Space.swift",
    "Shared/UI/Platform/PlatformSupport.swift", "Shared/UI/Platform/NativeOverlayScrollers.swift",
    "Shared/UI/Platform/MacSessionContextMenu.swift",
    "Shared/Core/Conversation/ChatHistoryPullState.swift",
    "Shared/Core/Conversation/ChatDiagramBlock.swift",
    "Shared/UI/Chat/ChatScrollView.swift", "Shared/UI/Chat/ChatMarkdown.swift",
    "Shared/UI/Chat/MacMarkdownTable.swift", "Shared/UI/Chat/MacConversationTable.swift",
    "Shared/UI/Chat/MacConversationTextDocument.swift", "Shared/UI/Chat/SelectableAttributedText.swift",
    "scripts/mac-chat-reflow/Support.swift", "scripts/mac-chat-boundaries/Probe.swift",
]

with tempfile.TemporaryDirectory(prefix="corral-mac-chat-boundaries-") as directory:
    executable = str(Path(directory) / "probe")
    timeline = (ROOT / "Shared/Core/Conversation/ConversationTimeline.swift").read_text()
    item = Path(directory) / "TimelineItem.swift"
    # Compile the production row DTO without unrelated transcript policies.
    item.write_text(timeline[:timeline.index("\n}\n") + 3])
    subprocess.run([
        "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", "-DCORRAL_REAL_MARKDOWN",
        *[str(ROOT / path) for path in SOURCES], str(item), "-o", executable,
    ], check=True)
    subprocess.run([executable], check=True)
