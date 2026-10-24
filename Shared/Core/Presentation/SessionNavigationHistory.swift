import Foundation

/// Browser-style visits, independent of session activity and sidebar sorting.
nonisolated struct SessionNavigationHistory: Equatable {
    private(set) var keys: [String] = []
    private(set) var index: Int = -1
    static let limit = 100

    var current: String? { keys.indices.contains(index) ? keys[index] : nil }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { keys.indices.contains(index + 1) }

    mutating func visit(_ key: String) {
        guard !key.isEmpty, current != key else { return }
        keys = Array(keys.prefix(index + 1))
        keys.append(key)
        if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
        index = keys.count - 1
    }

    @discardableResult
    mutating func move(to destination: Int) -> String? {
        guard keys.indices.contains(destination) else { return nil }
        index = destination
        return keys[index]
    }

    mutating func remove(_ key: String) {
        let before = keys.prefix(max(0, index + 1)).filter { $0 != key }.count
        keys.removeAll { $0 == key }
        index = keys.isEmpty ? -1 : min(max(0, before - 1), keys.count - 1)
    }

    mutating func replace(_ old: String, with new: String) {
        keys = keys.map { $0 == old ? new : $0 }
    }
}
