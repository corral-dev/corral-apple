#!/usr/bin/env python3
"""Build an isolated native focus study from a reproducible committed source."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--working-copy", action="store_true", help="Development only; final handoff uses committed HEAD")
    parser.add_argument("--export", action="store_true", help="Run the native scenario export and state checks")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    output = (args.output or config / "corral/design-previews/pane-focus").expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()

    def source(path: str) -> bytes:
        if args.working_copy:
            return (repo / path).read_bytes()
        return subprocess.check_output(["git", "show", revision + ":" + path], cwd=repo)

    bundle = output / "Corral Focus Study.app"
    contents = bundle / "Contents"
    executable = contents / "MacOS/FocusDemo"
    executable.parent.mkdir(parents=True, exist_ok=True)
    resources = contents / "Resources"
    resources.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="corral-focus-source-") as temporary:
        swift = Path(temporary) / "FocusDemo.swift"
        swift.write_bytes(source("scripts/pane-focus-demos/FocusDemo.swift"))
        result = subprocess.run([
            "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
            "-target", "arm64-apple-macosx26.0", str(swift), "-o", str(executable)
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output / "build.log").write_text(result.stdout)
        print(result.stdout, end="")
        result.check_returncode()
    for runtime in ["Claude", "Codex", "OpenCode", "Pi"]:
        for appearance in ["light", "dark"]:
            name = f"runtime{runtime.lower()}-{appearance}@2x.png"
            path = f"Shared/Resources/SharedAssets.xcassets/Runtime{runtime}.imageset/{name}"
            (resources / name).write_bytes(source(path))
    info = {
        "CFBundleName": "Corral Focus Study", "CFBundleDisplayName": "Corral Focus Study",
        "CFBundleIdentifier": "com.x0c.corral.focus-study", "CFBundleExecutable": "FocusDemo",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
        "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
        "SourceCommit": revision, "DevelopmentWorkingCopy": args.working_copy,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    if args.export:
        with tempfile.TemporaryDirectory(prefix="corral-focus-renders-") as temporary:
            rendered = Path(temporary) / "renders"
            with (output / "run.log").open("w") as log:
                subprocess.run([str(executable), "--export", str(rendered)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
            previous = output / "renders"
            if previous.exists():
                previous.rename(output / ("previous-renders-" + str(time.time_ns())))
            shutil.copytree(rendered, output / "renders")
    (output / "source-commit.txt").write_text(revision + (" (working copy)" if args.working_copy else "") + "\n")
    (output / "README.md").write_bytes(source("scripts/pane-focus-demos/README.md"))
    if not args.working_copy:
        with tempfile.TemporaryDirectory(prefix="corral-focus-package-") as temporary:
            stage = Path(temporary) / "Corral Focus Study"
            stage.mkdir()
            shutil.copytree(bundle, stage / bundle.name)
            for name in ["README.md", "source-commit.txt", "build.log"]:
                shutil.copy2(output / name, stage / name)
            if args.export:
                shutil.copytree(output / "renders", stage / "renders")
                shutil.copy2(output / "run.log", stage / "run.log")
            subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(output / "Corral-Focus-Study.zip")], check=True)
    print(bundle)


if __name__ == "__main__":
    main()
