#!/usr/bin/env python3
"""Measure the production Mac conversation streaming and document update cost.

Mounts the real native conversation table, its cells, the shared Markdown text
document, Markdown parsing and native tables, then appends tokens to the last
message like a streaming agent reply. Reports main-thread busy time per token at
short, medium and long conversations, plus the isolated document and Markdown
costs, and a plain-text control run that bypasses Markdown.

It also attributes the two user-visible spikes: opening a long conversation
(shared document render, every row measured through SwiftUI hosting, first
display, all reported separately and together, with and without non-contiguous
layout) and a text-size step (document re-render for the new style, then the row
measurement burst the new render key forces). A conversion section proves the
draw-text font pass leaves identical attributes and reports its cost, and the
engine section splits the detached measurement into storage set, first layout,
and the fitted-width second layout.

No pointer, keyboard, real session data or preferences are used. Timings are
main-thread busy time proxies, not WindowServer frame latency.
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
    "Shared/Core/Conversation/ChatHistoryPullState.swift",
    "Shared/Core/Conversation/ChatDiagramBlock.swift",
    "Shared/UI/Chat/ChatScrollView.swift", "Shared/UI/Chat/ChatMarkdown.swift",
    "Shared/UI/Chat/MacMarkdownTable.swift", "Shared/UI/Chat/MacConversationTable.swift",
    "Shared/UI/Chat/MacPathLinks.swift", "Shared/UI/Chat/MacConversationTextDocument.swift", "Shared/UI/Chat/SelectableAttributedText.swift",
    "Shared/UI/Chat/MessageBubbleView.swift", "macOS/Design/MacMotion.swift",
    "scripts/mac-chat-reflow/Support.swift",
    "scripts/mac-chat-stream/Probe.swift",
]
with tempfile.TemporaryDirectory(prefix="corral-mac-chat-stream-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-O", "-swift-version", "6", "-default-isolation", "MainActor",
                    "-parse-as-library", "-DCORRAL_REAL_MARKDOWN", "-DDEBUG",
                    *[str(ROOT / path) for path in SOURCES], "-o", executable], check=True)
    subprocess.run([executable, *sys.argv[1:]], check=True)
