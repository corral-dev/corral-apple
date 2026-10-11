#!/usr/bin/env python3
"""Mount the pooled Mac conversation table; inspect native reuse and behavior.

No pointer events, keyboard events, real session data or preferences are used.
This validates pooled rendering, selection, jumps and top loading, not
physical clicks or WindowServer rendering while the console is locked.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Shared/UI/Design/InterfaceScale.swift", "Shared/UI/Design/Typography.swift",
    "Shared/UI/Design/SessionTextSize.swift", "Shared/UI/Design/Space.swift",
    "Shared/UI/Platform/PlatformSupport.swift", "Shared/UI/Platform/NativeOverlayScrollers.swift",
    "Shared/Core/Conversation/ChatHistoryPullState.swift",
    "Shared/Core/Conversation/ConversationTimePolicy.swift",
    "Shared/Core/Models/RichMessageModels.swift",
    "Shared/Core/Models/RemoteDecoding.swift",
    "Shared/Core/Models/ScreenFrameModels.swift",
    "Shared/Core/Models/SessionSummaryModels.swift",
    "Shared/Core/Presentation/SessionPresentation.swift",
    "Shared/Core/Models/PromptModels.swift",
    "Shared/Core/Conversation/ConversationTimeline.swift",
    "Shared/UI/Chat/ChatTimeSeparator.swift",
    "Shared/UI/Chat/MacConversationTextDocument.swift",
    "Shared/UI/Chat/SelectableAttributedText.swift",
    "Shared/UI/Chat/MessageBubbleView.swift",
    "Shared/UI/Chat/ToolActivityView.swift",
    "Shared/UI/Chat/AnswerOptionsView.swift",
    "Shared/UI/Chat/ChatActivityFooter.swift",
    "macOS/Design/MacWorkingDots.swift",
    "Shared/UI/Chat/MacPooledConversationList.swift",
    "scripts/mac-pooled-list/Support.swift",
    "scripts/mac-pooled-list/Probe.swift",
]
with tempfile.TemporaryDirectory(prefix="corral-mac-pooled-list-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
                    *[str(ROOT / path) for path in SOURCES], "-o", executable], check=True)
    subprocess.run([executable], check=True)
