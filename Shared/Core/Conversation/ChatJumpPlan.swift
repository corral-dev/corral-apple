import Foundation

/// A message jump glides when the target is within a few screens of the
/// viewport; farther targets fade through instead (see `ChatScrollView`).
enum ChatJumpPlan {
    static let glideRows = 30

    static func glides(in ids: [String], target: String, visible: String?) -> Bool {
        guard let targetIndex = ids.firstIndex(of: target) else { return false }
        // Unknown viewport: assume the reader sits at the latest messages.
        let visibleIndex = visible.flatMap { ids.firstIndex(of: $0) } ?? ids.count - 1
        return abs(visibleIndex - targetIndex) <= glideRows
    }
}
