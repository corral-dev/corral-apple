#!/usr/bin/env python3
"""Decisive A/B for the jump-break defect W3 filed.

Runs the frozen stream probe's settle gate with the arrival changed from an
incremental scroll to a single bottom->top teleport, once against the committed
conversation table and once against the working tree, so a clipped row after a
text-scale change can be attributed to this round's changes or to pre-existing
behaviour.

Read-only for the repository: both tables, the patched probe and the binaries
live in a temp directory.
"""
from pathlib import Path
import subprocess
import sys
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
    "Shared/UI/Chat/MacMarkdownTable.swift",
    "Shared/UI/Chat/MacPathLinks.swift", "Shared/UI/Chat/MacConversationTextDocument.swift",
    "Shared/UI/Chat/SelectableAttributedText.swift",
    "Shared/UI/Chat/MessageBubbleView.swift", "macOS/Design/MacMotion.swift",
    "scripts/mac-chat-reflow/Support.swift",
]
OLD = """            let fromY = scrollView.contentView.bounds.origin.y
            let steps = max(1, Int(abs(y - fromY) / 200) + 1)
            for step in 1...steps {
                let yy = fromY + (y - fromY) * CGFloat(step) / CGFloat(steps)
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: yy))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
                if let window = host.window { window.displayIfNeeded() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }"""
NEW = """            // Teleport in one step: the pre-gate arrival the gate now avoids.
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            host.layoutSubtreeIfNeeded()
            if let window = host.window { window.displayIfNeeded() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))"""

with tempfile.TemporaryDirectory(prefix="corral-jump-ab-") as raw:
    directory = Path(raw)
    probe = ROOT / "scripts/mac-chat-stream/Probe.swift"
    source = probe.read_text()
    assert OLD in source, "arrival code changed; update this harness"
    patched = directory / "ProbeJump.swift"
    patched.write_text(source.replace(OLD, NEW))
    head = directory / "MacConversationTable.head.swift"
    head.write_text(subprocess.run(
        ["git", "show", "HEAD:Shared/UI/Chat/MacConversationTable.swift"],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout)
    arms = {"HEAD": head, "work": ROOT / "Shared/UI/Chat/MacConversationTable.swift"}
    for name, table in arms.items():
        executable = str(directory / f"jump-{name}")
        subprocess.run([
            "swiftc", "-O", "-swift-version", "6", "-default-isolation", "MainActor",
            "-parse-as-library", "-DCORRAL_REAL_MARKDOWN", "-DDEBUG",
            *[str(ROOT / path) for path in SOURCES], str(table), str(patched),
            "-o", executable,
        ], check=True)
        print(f"=== {name} ===", flush=True)
        result = subprocess.run([executable], capture_output=True, text=True, check=False)
        for line in result.stdout.splitlines():
            if "settle parity" in line or "empty containers" in line:
                print(" ", line.strip())
        print("  exit", result.returncode, flush=True)
