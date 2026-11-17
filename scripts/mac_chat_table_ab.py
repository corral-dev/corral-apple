#!/usr/bin/env python3
"""Coordinator A/B: HEAD conversation table vs the working-tree table.

Compiles the frozen stream probe twice - once against the committed
`MacConversationTable.swift` (git show HEAD:...) and once against the working
copy - then runs the two binaries in an interleaved sequence so ambient machine
load hits both arms equally. Reports the median of per-arm medians for the
text-scale headline, plus the first-scroll max, so a scheduling change can be
accepted on comparable numbers instead of two runs at different load.

Read-only for the repository: the HEAD copy and both binaries live in a temp
directory. No pointer, keyboard, real session data or preferences are used.
"""
from pathlib import Path
import statistics
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
    "scripts/mac-chat-reflow/Support.swift",
    "scripts/mac-chat-stream/Probe.swift",
]
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 3


def build(directory: Path, table: Path, name: str) -> str:
    executable = str(directory / name)
    subprocess.run([
        "swiftc", "-O", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", "-DCORRAL_REAL_MARKDOWN", "-DDEBUG",
        *[str(ROOT / path) for path in SOURCES], str(table), "-o", executable,
    ], check=True)
    return executable


def metric(output: str, label: str, field: str) -> float | None:
    for line in output.splitlines():
        if line.strip().startswith(label):
            parts = line.split()
            for index, token in enumerate(parts):
                if token == field and index + 1 < len(parts):
                    return float(parts[index + 1])
    return None


with tempfile.TemporaryDirectory(prefix="corral-a-b-") as raw:
    directory = Path(raw)
    head = directory / "MacConversationTable.head.swift"
    head.write_text(subprocess.run(
        ["git", "show", "HEAD:Shared/UI/Chat/MacConversationTable.swift"],
        cwd=ROOT, check=True, capture_output=True, text=True).stdout)
    working = ROOT / "Shared/UI/Chat/MacConversationTable.swift"
    arms = {
        "HEAD": build(directory, head, "probe-head"),
        "work": build(directory, working, "probe-work"),
    }
    results: dict[str, dict[str, list[float]]] = {
        name: {"text-scale": [], "scroll": []} for name in arms
    }
    for round_index in range(ROUNDS):
        for name, executable in arms.items():
            output = subprocess.run([executable], capture_output=True, text=True,
                                    check=False).stdout
            scale = metric(output, "text-scale step size=120", "median")
            scroll = metric(output, "scroll 60pt/step size=120", "max")
            if scale is not None:
                results[name]["text-scale"].append(scale)
            if scroll is not None:
                results[name]["scroll"].append(scroll)
        print(f"round {round_index + 1}/{ROUNDS} done", flush=True)

    print()
    for name in arms:
        for key in ("text-scale", "scroll"):
            samples = results[name][key]
            if not samples:
                print(f"{name:5} {key:12} no samples")
                continue
            print(f"{name:5} {key:12} median {statistics.median(samples):7.1f} ms  "
                  f"min {min(samples):7.1f}  max {max(samples):7.1f}  n {len(samples)}")
