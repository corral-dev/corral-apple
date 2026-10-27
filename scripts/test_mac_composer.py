#!/usr/bin/env python3
"""Native production composer regression; no user sessions or pointer input."""
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    "Shared/UI/Composer/ComposerBar.swift", "Shared/UI/Composer/ImageAttachmentEncoder.swift",
    "Shared/UI/Composer/DraftImagePreview.swift", "Shared/UI/Composer/DraftImageInspection.swift", "Shared/UI/Design/Space.swift",
    "Shared/UI/Design/InterfaceScale.swift", "Shared/UI/Design/SessionTextSize.swift",
    "Shared/UI/Design/Typography.swift", "Shared/UI/Design/PressableButtonStyle.swift",
    "Shared/UI/Platform/PlatformSupport.swift", "Shared/UI/Platform/MacSessionContextMenu.swift",
    "Shared/Core/Conversation/ChatComposerPolicy.swift",
    "Shared/Core/Conversation/ComposerHistory.swift", "Shared/UI/Chat/MacConversationTextDocument.swift",
    "scripts/mac-composer/Support.swift", "scripts/mac-composer/Probe.swift",
]
with tempfile.TemporaryDirectory(prefix="corral-mac-composer-") as directory:
    executable = str(Path(directory) / "probe")
    subprocess.run(["swiftc", "-swift-version", "6", "-default-isolation", "MainActor", "-parse-as-library",
                    *[str(ROOT / path) for path in SOURCES], "-o", executable], check=True)
    subprocess.run([executable, *sys.argv[1:]], check=True)
