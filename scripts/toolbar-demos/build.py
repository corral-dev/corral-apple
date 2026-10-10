#!/usr/bin/env python3
"""Package committed native toolbar demo sources without touching Corral."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(*argv: str, cwd: Path | None = None) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    commit = run("git", "rev-parse", "HEAD", cwd=repo)
    config = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
    output = (args.output or config / "corral/design-previews/toolbar").expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="corral-toolbar-source-") as temporary:
        source = Path(temporary) / "ToolbarDemo.swift"
        source.write_bytes(subprocess.check_output([
            "git", "show", commit + ":scripts/toolbar-demos/ToolbarDemo.swift"
        ], cwd=repo))
        executable = Path(temporary) / "ToolbarDemo"
        result = subprocess.run([
            "xcrun", "swiftc", "-O", "-swift-version", "6", "-parse-as-library",
            "-target", "arm64-apple-macosx26.0", str(source), "-o", str(executable)
        ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (output / "build.log").write_text(result.stdout)
        if result.stdout:
            print(result.stdout, end="")
        result.check_returncode()
        for variant in "abc":
            name = "Corral Demo " + variant.upper()
            bundle = output / (name + ".app")
            if bundle.exists():
                expected = "com.x0c.corral.toolbar-demo." + variant
                existing = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
                if existing.get("CFBundleIdentifier") != expected:
                    raise SystemExit("Refusing to replace a bundle with a different identity: " + str(bundle))
                backup = output / (name + ".previous.app")
                if backup.exists():
                    shutil.rmtree(backup)
                bundle.rename(backup)
            contents = bundle / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            shutil.copy2(executable, contents / "MacOS/ToolbarDemo")
            info = {
                "CFBundleName": name, "CFBundleDisplayName": name,
                "CFBundleIdentifier": "com.x0c.corral.toolbar-demo." + variant,
                "CFBundleExecutable": "ToolbarDemo", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1.0",
                "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": True,
                "DemoVariant": variant, "SourceCommit": commit
            }
            (contents / "Info.plist").write_bytes(plistlib.dumps(info))
            subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True)
            subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    archive = output / "Corral-Toolbar-Demos.zip"
    with tempfile.TemporaryDirectory(prefix="corral-toolbar-package-") as temporary:
        stage = Path(temporary) / "Corral Toolbar Demos"
        stage.mkdir()
        for variant in "ABC":
            shutil.copytree(output / ("Corral Demo " + variant + ".app"), stage / ("Corral Demo " + variant + ".app"))
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(archive)], check=True)
    (output / "source-commit.txt").write_text(commit + "\n")
    print("Source: " + commit)
    print("Apps and archive: " + str(output))
    if args.open:
        for variant in "ABC":
            subprocess.run(["open", str(output / ("Corral Demo " + variant + ".app"))], check=True)


if __name__ == "__main__":
    main()
