#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import Corral

nonisolated final class NewSessionChoiceLayoutTests: XCTestCase {
    @MainActor
    func testContentSizedChoicesWrapWithoutOverlappingOrStretching() async throws {
        for (width, type, dark) in [(CGFloat(390), DynamicTypeSize.large, false),
                                    (320, .large, true), (390, .accessibility3, false)] {
            let frames = ChoiceFrames()
            let root = ChoiceFixture(frames: frames)
                .environment(\.dynamicTypeSize, type)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: width, alignment: .topLeading)
            let host = UIHostingController(rootView: root)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1500))
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            for _ in 0..<30 {
                if frames.values.count == 14 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(frames.values.count, 14)
            for rect in frames.values.values {
                XCTAssertGreaterThanOrEqual(rect.height, 44)
                XCTAssertGreaterThanOrEqual(rect.minX, 15)
                XCTAssertLessThanOrEqual(rect.maxX, width - 15)
            }
            let values = Array(frames.values.values)
            for i in values.indices {
                for j in values.indices where j > i {
                    XCTAssertFalse(values[i].insetBy(dx: 0.5, dy: 0.5).intersects(values[j]))
                }
            }
            if width == 390 && type == .large {
                let claude = try XCTUnwrap(frames.values["assistant-claude"])
                let pi = try XCTUnwrap(frames.values["assistant-pi"])
                let openCode = try XCTUnwrap(frames.values["assistant-opencode"])
                XCTAssertEqual(claude.minY, openCode.minY, accuracy: 1,
                               "The first three assistants fit on one row at phone width")
                XCTAssertLessThan(pi.width, openCode.width - 20,
                                  "A short label must not inherit the longest label's width")
            }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "new-session-choices-\(Int(width))-\(type)-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("NEW_SESSION_CHOICES width=\(width) type=\(type) frames=\(frames.values)")
        }
    }
}

@MainActor private final class ChoiceFrames {
    var values: [String: CGRect] = [:]
}

/// Hosts the production buttons and flow at phone widths; it is layout evidence,
/// not a paired-device or session-creation acceptance substitute.
private struct ChoiceFixture: View {
    let frames: ChoiceFrames
    private let assistants = [("claude", "Claude"), ("codex", "Codex"),
                              ("opencode", "OpenCode"), ("cursor", "Cursor"), ("pi", "Pi")]
    private let projects = ["Corral", "Codes", "WaterfallNotes"]
    private let recent = [("codex", "Corral"), ("codex", "ProxyAgent"),
                          ("opencode", "Codes"), ("opencode", "Corral"), ("opencode", "ProxyAgent")]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("助手").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                NewSessionChoiceFlow {
                    ForEach(assistants, id: \.0) { runtime in
                        measured("assistant-\(runtime.0)") {
                            NewSessionChoiceButton(selected: runtime.0 == "codex") {
                                logo(runtime.0)
                                Text(verbatim: runtime.1)
                            } action: {}
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("项目").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                NewSessionChoiceFlow {
                    ForEach(projects, id: \.self) { project in
                        measured("project-\(project)") {
                            NewSessionChoiceButton(selected: project == "Corral") {
                                Text(verbatim: project)
                            } action: {}
                        }
                    }
                    measured("more") {
                        NewSessionChoiceButton {
                            Text("更多")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        } action: {}
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("快捷启动").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                NewSessionChoiceFlow {
                    ForEach(recent.indices, id: \.self) { index in
                        measured("recent-\(index)") {
                            NewSessionChoiceButton {
                                logo(recent[index].0)
                                Text(verbatim: recent[index].1)
                            } action: {}
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemGroupedBackground))
        .coordinateSpace(name: "choice-fixture")
    }

    private func measured<V: View>(_ id: String, @ViewBuilder content: () -> V) -> some View {
        content().onGeometryChange(for: CGRect.self) { $0.frame(in: .named("choice-fixture")) } action: {
            frames.values[id] = $0
        }
    }

    @ViewBuilder private func logo(_ runtime: String) -> some View {
        if let name = Palette.runtimeLogoName(runtime) {
            Image(name).resizable().renderingMode(.original).scaledToFit().frame(width: 20, height: 20)
        }
    }
}
#endif
