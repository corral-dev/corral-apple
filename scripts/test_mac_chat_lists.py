#!/usr/bin/env python3
"""Mac list-first message layout regression.

Compiles the production conversation text document (shared TextKit network) with
ChatMarkdown and checks that a message whose first line is a list keeps its
marker flush and its item text on the same line, at the same height the row was
measured for. Fixture text only; no sessions, preferences or pointer events.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Shared/UI/Design/InterfaceScale.swift",
    "Shared/UI/Platform/PlatformSupport.swift",
    "Shared/UI/Platform/MacSessionContextMenu.swift",
    "Shared/Core/Conversation/ChatDiagramBlock.swift",
    "Shared/UI/Chat/ChatMarkdown.swift",
    "Shared/UI/Chat/MacConversationTextDocument.swift",
    "scripts/mac-chat-lists/Probe.swift",
]


def build_and_run(overrides: dict[str, Path] | None = None) -> subprocess.CompletedProcess:
    overrides = overrides or {}
    with tempfile.TemporaryDirectory(prefix="corral-mac-chat-lists-") as directory:
        executable = str(Path(directory) / "probe")
        paths = [str(overrides.get(source, ROOT / source)) for source in SOURCES]
        subprocess.run(
            [
                "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
                "-parse-as-library", *paths, "-o", executable,
            ],
            check=True,
        )
        return subprocess.run([executable], capture_output=True, text=True)


if __name__ == "__main__":
    result = build_and_run()
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    sys.exit(result.returncode)
