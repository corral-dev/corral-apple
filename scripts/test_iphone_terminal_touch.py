#!/usr/bin/env python3
"""Run the production UIKit terminal with an isolated transport on a disposable simulator.

No pointer events are injected. This is native component evidence, not physical
iPhone gesture/visual acceptance. Requires an existing simulator SwiftTerm build.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--derived-data", type=Path, default=ROOT / ".derivedData")
args = parser.parse_args()
products = args.derived_data.resolve() / "Build/Products/Debug-iphonesimulator"
if not (products / "SwiftTerm.o").is_file():
    parser.error("Build the iOS Debug simulator target in the selected derived-data directory first")


def run(*argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, **kwargs)


def output(*argv):
    return run(*argv, stdout=subprocess.PIPE).stdout.strip()


with tempfile.TemporaryDirectory(prefix="corral-phone-touch-") as directory:
    app = Path(directory) / "TerminalTouchProbe.app"
    app.mkdir()
    sdk = output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
    run("xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-default-isolation", "MainActor",
        "-parse-as-library", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator",
        "-I", str(products),
        str(ROOT / "Shared/UI/Terminal/TerminalColors.swift"),
        str(ROOT / "Shared/UI/Terminal/TerminalHostFeed.swift"),
        str(ROOT / "Shared/UI/Terminal/TerminalPromptNavigation.swift"),
        str(ROOT / "iOS/Views/Terminal/ShellTerminalView.swift"),
        str(ROOT / "iOS/Views/Terminal/TerminalTouchInteraction.swift"),
        str(ROOT / "scripts/iphone-terminal-touch/Probe.swift"),
        str(products / "SwiftTerm.o"), "-o", str(app / "Probe"),
        env={**os.environ, "SDKROOT": sdk})
    bundle_id = "dev.corral.TerminalTouchProbe"
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Probe",
        "CFBundleName": "TerminalTouchProbe", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0", "UIDeviceFamily": [1], "UILaunchScreen": {},
        "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        "UIApplicationSceneManifest": {
            "UIApplicationSupportsMultipleScenes": False,
            "UISceneConfigurations": {"UIWindowSceneSessionRoleApplication": [{"UISceneConfigurationName": "Probe"}]},
        },
    }))
    resource = products / "SwiftTerm_SwiftTerm.bundle"
    if resource.is_dir():
        shutil.copytree(resource, app / resource.name)
    run("codesign", "--force", "--sign", "-", str(app))
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    runtime = next(r for r in runtimes if r.get("isAvailable") and ".iOS-" in r["identifier"]
                   and any(d.get("productFamily") == "iPhone" for d in r.get("supportedDeviceTypes", [])))
    device_type = next(d["identifier"] for d in runtime["supportedDeviceTypes"]
                       if d.get("productFamily") == "iPhone")
    device = output("xcrun", "simctl", "create", "Corral terminal touch checks",
                    device_type, runtime["identifier"])
    try:
        run("xcrun", "simctl", "boot", device)
        run("xcrun", "simctl", "bootstatus", device, "-b", timeout=180)
        run("xcrun", "simctl", "install", device, str(app))
        run("xcrun", "simctl", "launch", "--console", device, bundle_id, timeout=90)
        container = Path(output("xcrun", "simctl", "get_app_container", device, bundle_id, "data"))
        result = json.loads((container / "tmp/touch-result.json").read_text())
        print(json.dumps(result, indent=2))
        if not result["ok"]:
            raise SystemExit(1)
    finally:
        subprocess.run(["xcrun", "simctl", "shutdown", device], capture_output=True)
        run("xcrun", "simctl", "delete", device)
