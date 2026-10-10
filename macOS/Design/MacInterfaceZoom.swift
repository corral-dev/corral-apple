import Foundation
import Observation

/// One local display preference, shared across Mac scenes, never sent to a host.
@MainActor
@Observable
final class MacInterfaceZoom {
    static let minimum = 80
    static let maximum = 150
    static let step = 10
    private(set) var percentage: Int
    private(set) var persistenceFailed = false
    private let fileURL: URL

    var scale: CGFloat { CGFloat(percentage) / 100 }
    var canIncrease: Bool { percentage < Self.maximum }
    var canDecrease: Bool { percentage > Self.minimum }

    init(fileURL: URL = AppStorageLocation.appDirectory.appendingPathComponent("interface-zoom.json")) {
        self.fileURL = fileURL
        let stored = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode(Int.self, from: $0) }
        percentage = Self.normalized(stored ?? 100)
    }

    func increase() { setPercentage(percentage + Self.step) }
    func decrease() { setPercentage(percentage - Self.step) }
    func reset() { setPercentage(100) }

    func setPercentage(_ value: Int) {
        let next = Self.normalized(value)
        guard next != percentage || persistenceFailed else { return }
        let focus = MacZoomFocusSnapshot.capture()
        percentage = next
        focus?.restoreAfterLayout()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: fileURL, options: .atomic)
            persistenceFailed = false
        } catch {
            persistenceFailed = true
        }
    }

    private static func normalized(_ value: Int) -> Int {
        let bounded = min(max(value, minimum), maximum)
        return Int((Double(bounded) / Double(step)).rounded()) * step
    }
}
