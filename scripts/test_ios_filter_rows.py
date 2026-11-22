#!/usr/bin/env python3
"""Mount production iOS SessionRuntimeFilterRow + SessionProjectFilterRow at 390pt."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

PROBE_SWIFT = r'''
import SwiftUI
import UIKit

enum AppModel {
    enum ConnectionState: Equatable {
        case disconnected, connecting, reconnecting, connected, failed
    }
}

nonisolated enum SessionListLayout {
    static let rowHorizontal: CGFloat = 16
}

private struct FilterRowFixture: View {
    let sessions: [SessionSummary]
    let choices: [SessionProjectOption]
    @State var quickFilter: SessionQuickFilter
    @State var runtimes: Set<SessionRuntimeFilter>
    @State var projects: Set<SessionProjectFilter>

    var body: some View {
        VStack(spacing: 0) {
            SessionRuntimeFilterRow(
                quickFilter: $quickFilter,
                sessions: sessions,
                selected: $runtimes
            )
            .padding(.top, Space.xs)
            SessionProjectFilterRow(
                selected: $projects,
                choices: choices,
                selectedOutside: [],
                onMore: {}
            )
            .padding(.bottom, Space.xs)
            Divider()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
    }
}

private func findScrollViews(in view: UIView) -> [UIScrollView] {
    var result: [UIScrollView] = []
    if let sv = view as? UIScrollView { result.append(sv) }
    for sub in view.subviews { result.append(contentsOf: findScrollViews(in: sub)) }
    return result
}

struct RuntimeBoundsMarker: UIViewRepresentable {
    @MainActor static var views: [String: UIView] = [:]
    let id: String
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        Self.views[id] = v
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        Self.views[id] = v
    }
}

@main
final class ProbeAppDelegate: UIResponder, UIApplicationDelegate, UIWindowSceneDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Probe", sessionRole: connectingSceneSession.role)
        config.delegateClass = ProbeAppDelegate.self
        return config
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        window.makeKeyAndVisible()
        Task { @MainActor in
            await runProbe(in: windowScene)
            exit(0)
        }
    }

    @MainActor
    private func runProbe(in windowScene: UIWindowScene) async {
        let sessions = [
            SessionSummary(key: "claude:1", runtime: "claude", cwd: "/tmp/NeatMark", attention: .waiting, marker: "waiting", needsAttention: true),
            SessionSummary(key: "codex:1", runtime: "codex", cwd: "/tmp/Forenote", attention: .working, marker: "working", needsAttention: true),
            SessionSummary(key: "opencode:1", runtime: "opencode", cwd: "/tmp/LanVNC", attention: .unread, marker: "unread", needsAttention: true),
            SessionSummary(key: "cursor:1", runtime: "cursor", cwd: "/tmp/Codes", needsAttention: false),
            SessionSummary(key: "pi:1", runtime: "pi", cwd: "/tmp/Corral", needsAttention: true),
            SessionSummary(key: "antigravity:1", runtime: "antigravity", cwd: "/tmp/LanVNC", attention: .working, marker: "working", needsAttention: true),
        ] + (0..<9).map { i in
            SessionSummary(key: "claude:extra\(i)", runtime: "claude", cwd: "/tmp/NeatMark", attention: .waiting, marker: "waiting", needsAttention: true)
        }
        let choices = SessionListFiltering.reconcileChoices(current: [], sessions: sessions)

        var cases: [[String: Any]] = []
        var failures: [String] = []
        var avgGapByCase: [String: CGFloat] = [:]

        for (name, width, dark, quick, selRuntimes, selProjects) in [
            ("light-390", CGFloat(390), false, SessionQuickFilter.all, Set<SessionRuntimeFilter>([.antigravity]), Set<SessionProjectFilter>([.project(path: "/tmp/LanVNC")])),
            ("dark-440", CGFloat(440), true, SessionQuickFilter.active, Set(SessionRuntimeFilter.ordered.filter { $0 != .all }), Set<SessionProjectFilter>()),
        ] {
            RuntimeBoundsMarker.views = [:]
            let root = FilterRowFixture(
                sessions: sessions,
                choices: choices,
                quickFilter: quick,
                runtimes: selRuntimes,
                projects: selProjects
            )
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width, height: 140, alignment: .topLeading)

            let host = UIHostingController(rootView: root)
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            if #available(iOS 16.4, *) {
                host.safeAreaRegions = []
            }
            let containerView = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 140))
            let testWindow = UIWindow(windowScene: windowScene)
            testWindow.frame = CGRect(x: 0, y: 0, width: max(width, windowScene.screen.bounds.width), height: 220)
            testWindow.overrideUserInterfaceStyle = dark ? .dark : .light
            testWindow.addSubview(containerView)
            host.view.frame = containerView.bounds
            host.view.autoresizingMask = []
            containerView.addSubview(host.view)
            testWindow.isHidden = false
            containerView.setNeedsLayout()
            containerView.layoutIfNeeded()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(40))
                host.view.frame = containerView.bounds
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
            }

            let scrollViews = findScrollViews(in: containerView)
            guard let row1 = scrollViews.first else {
                failures.append("\(name): missing row1 UIScrollView")
                testWindow.isHidden = true
                continue
            }
            let contentW = row1.contentSize.width
            let viewportW = row1.bounds.width
            let fits = contentW <= viewportW + 0.5 && viewportW > 300
            if !fits {
                failures.append("\(name): row1 overflows content=\(contentW) viewport=\(viewportW)")
            }
            if row1.bounds.height < TouchTarget.minimum - 0.5 || row1.bounds.height > TouchTarget.minimum + 1.5 {
                failures.append("\(name): row1 height \(row1.bounds.height) outside ~\(TouchTarget.minimum)")
            }
            let mounted = RuntimeBoundsMarker.views.values.filter { $0.window === testWindow }
            let runtimeButtons = mounted
                .map { $0.convert($0.bounds, to: row1) }
                .sorted { $0.minX < $1.minX }
            let runtimeGaps = zip(runtimeButtons, runtimeButtons.dropFirst()).map { $1.minX - $0.maxX }
            let runtimeWidths = runtimeButtons.map(\.width)
            let avgGap = runtimeGaps.isEmpty ? 0 : runtimeGaps.reduce(0, +) / CGFloat(runtimeGaps.count)
            let avgWidth = runtimeWidths.isEmpty ? 0 : runtimeWidths.reduce(0, +) / CGFloat(runtimeWidths.count)
            let trailingGap = runtimeButtons.last.map { row1.bounds.maxX - $0.maxX } ?? viewportW
            if runtimeButtons.count != 6 {
                failures.append("\(name): expected 6 runtime bounds markers, got \(runtimeButtons.count)")
            }
            if let maxG = runtimeGaps.max(), let minG = runtimeGaps.min(), maxG - minG > 1.5 {
                failures.append("\(name): unequal runtime gaps \(runtimeGaps)")
            }
            if let maxW = runtimeWidths.max(), let minW = runtimeWidths.min(), maxW - minW > 1.5 {
                failures.append("\(name): unequal runtime button widths \(runtimeWidths)")
            }
            if abs(trailingGap) > 2.5 {
                failures.append("\(name): trailing edge gap \(trailingGap) exceeds 2.5pt (not edge-aligned)")
            }
            avgGapByCase[name] = avgWidth

            let image = UIGraphicsImageRenderer(bounds: containerView.bounds).image { _ in
                containerView.drawHierarchy(in: containerView.bounds, afterScreenUpdates: true)
            }
            if let data = image.pngData() {
                let path = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("filter-rows-\(name).png")
                try? data.write(to: path, options: .atomic)
            }
            cases.append([
                "name": name,
                "contentWidth": contentW,
                "viewportWidth": viewportW,
                "rowHeight": row1.bounds.height,
                "avgRuntimeGap": avgGap,
                "avgRuntimeWidth": avgWidth,
                "trailingGap": trailingGap,
                "fits": fits,
            ])
            testWindow.isHidden = true
            containerView.removeFromSuperview()
        }

        if let w390 = avgGapByCase["light-390"], let w440 = avgGapByCase["dark-440"] {
            if !(w440 > w390 + 4.0) {
                failures.append("Adaptive button width failed to grow from 390pt (\(w390)) to 440pt (\(w440))")
            }
            if w390 < 38.0 - 0.5 || w440 > 50.0 + 0.5 {
                failures.append("Button widths out of bounds [38, 50]: 390=\(w390) 440=\(w440)")
            }
        }

        let report: [String: Any] = [
            "ok": failures.isEmpty && cases.count == 2,
            "cases": cases,
            "failures": failures,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let outPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("filter-rows-result.json")
            try? data.write(to: outPath, options: .atomic)
        }
    }
}
'''


def run(*argv, **kwargs):
    return subprocess.run(argv, check=True, text=True, **kwargs)


def output(*argv):
    return run(*argv, stdout=subprocess.PIPE).stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path, default=ROOT / ".derivedData-sim")
    parser.add_argument("--device-id", default="")
    args = parser.parse_args()

    built_app = args.derived_data.resolve() / "Build/Products/Debug-iphonesimulator/Corral.app"
    if not built_app.is_dir():
        raise SystemExit(f"Build the iOS Debug simulator target first: missing {built_app}")

    with tempfile.TemporaryDirectory(prefix="corral-ios-filters-") as directory:
        tmp = Path(directory)
        app = tmp / "FilterRowsProbe.app"
        app.mkdir()
        probe_swift = tmp / "Probe.swift"
        probe_swift.write_text(PROBE_SWIFT)

        filter_rows_copy = tmp / "SessionFilterRows.swift"
        filter_rows_src = (ROOT / "iOS/Views/Sessions/SessionFilterRows.swift").read_text()
        marker_target = ".accessibilityLabel(Text(verbatim: Palette.runtimeDisplayName(option.rawValue)))"
        assert marker_target in filter_rows_src
        filter_rows_copy.write_text(filter_rows_src.replace(
            marker_target,
            marker_target + "\n                    .background(RuntimeBoundsMarker(id: option.rawValue))"
        ))

        sdk = output("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
        sources = [
            *sorted((ROOT / "Shared/Core").rglob("*.swift")),
            ROOT / "Shared/UI/Design/Space.swift",
            ROOT / "Shared/UI/Design/InterfaceScale.swift",
            ROOT / "Shared/UI/Design/Palette.swift",
            ROOT / "Shared/UI/Design/HapticFeedback.swift",
            ROOT / "Shared/UI/Design/Typography.swift",
            ROOT / "Shared/UI/Design/SessionTextSize.swift",
            ROOT / "Shared/UI/Platform/PlatformSupport.swift",
            ROOT / "Shared/UI/Platform/InspectionLaunchOptions.swift",
            ROOT / "Shared/UI/Sessions/AdaptiveFilterRowLayout.swift",
            ROOT / "Shared/UI/Sessions/ProjectFilterSummaryLabel.swift",
            filter_rows_copy,
            probe_swift,
        ]
        run(
            "xcrun", "--sdk", "iphonesimulator", "swiftc",
            "-D", "DEBUG", "-swift-version", "6", "-default-isolation", "MainActor",
            "-parse-as-library", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator",
            *[str(s) for s in sources],
            "-o", str(app / "Probe"),
            env={**os.environ, "SDKROOT": sdk},
        )
        for item in ("Assets.car", "en.lproj", "zh-Hans.lproj"):
            src = built_app / item
            if src.is_dir():
                shutil.copytree(src, app / item)
            elif src.is_file():
                shutil.copy2(src, app / item)

        bundle_id = "dev.corral.FilterRowsProbe"
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": bundle_id,
            "CFBundleExecutable": "Probe",
            "CFBundleName": "FilterRowsProbe",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "CFBundleDevelopmentRegion": "en",
            "MinimumOSVersion": "17.0",
            "UIDeviceFamily": [1],
            "UILaunchScreen": {},
            "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
            "UIApplicationSceneManifest": {
                "UIApplicationSupportsMultipleScenes": False,
                "UISceneConfigurations": {
                    "UIWindowSceneSessionRoleApplication": [{"UISceneConfigurationName": "Probe"}]
                },
            },
        }))
        run("codesign", "--force", "--sign", "-", str(app))

        created_device = None
        device = args.device_id
        if not device:
            devices_json = json.loads(output("xcrun", "simctl", "list", "devices", "booted", "--json"))
            for devs in devices_json.get("devices", {}).values():
                for d in devs:
                    if d.get("state") == "Booted":
                        device = d["udid"]
                        break
                if device:
                    break
        if not device:
            runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
            runtime = next(
                r for r in runtimes
                if r.get("isAvailable") and ".iOS-" in r["identifier"]
                and any(d.get("productFamily") == "iPhone" for d in r.get("supportedDeviceTypes", []))
            )
            device_type = next(
                d["identifier"] for d in runtime["supportedDeviceTypes"]
                if d.get("productFamily") == "iPhone"
            )
            created_device = output(
                "xcrun", "simctl", "create", "Corral filter rows check",
                device_type, runtime["identifier"]
            )
            device = created_device
            run("xcrun", "simctl", "boot", device)
            run("xcrun", "simctl", "bootstatus", device, "-b", timeout=180)

        try:
            run("xcrun", "simctl", "install", device, str(app))
            run("xcrun", "simctl", "launch", "--console", device, bundle_id, timeout=90)
            container = Path(output("xcrun", "simctl", "get_app_container", device, bundle_id, "data"))
            result = json.loads((container / "tmp/filter-rows-result.json").read_text())
            for name in ("light-390", "dark-440"):
                snap = container / f"tmp/filter-rows-{name}.png"
                if snap.is_file():
                    shutil.copy2(snap, f"/tmp/corral-ios-filters-{name}.png")
            print(json.dumps(result, indent=2))
            if not result.get("ok"):
                return 1
        finally:
            subprocess.run(["xcrun", "simctl", "uninstall", device, bundle_id], capture_output=True)
            if created_device:
                subprocess.run(["xcrun", "simctl", "shutdown", created_device], capture_output=True)
                subprocess.run(["xcrun", "simctl", "delete", created_device], capture_output=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
