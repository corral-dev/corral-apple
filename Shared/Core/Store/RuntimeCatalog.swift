import Foundation
import Observation

/// Connection-owned handoff choices. Failure is not an empty catalog or an
/// indefinitely running request; explicit retry shares the same single flight.
@MainActor @Observable
final class RuntimeCatalog {
    private(set) var runtimes: [RuntimeEntry] = []
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private weak var owner: AnyObject?
    @ObservationIgnored private var generation = 0

    func reset() {
        generation &+= 1
        owner = nil
        runtimes = []
        isLoaded = false
        isLoading = false
        errorMessage = nil
    }

    func load(for owner: AnyObject, retry: Bool = false, call: () async throws -> Any) async {
        if self.owner !== owner {
            reset()
            self.owner = owner
        }
        guard !isLoading, !isLoaded || retry else { return }
        generation &+= 1
        let request = generation
        isLoading = true
        errorMessage = nil
        defer {
            if generation == request { isLoading = false }
        }
        do {
            let payload = try await call()
            try Task.checkCancellation()
            guard generation == request else { return }
            guard let data = payload as? [String: Any],
                  let items = data["runtimes"] as? [[String: Any]] else {
                throw InvalidResponse()
            }
            let decoded = try items.map { try RemoteJSONDecoder.decode(RuntimeEntry.self, from: $0) }
            runtimes = decoded.filter(\.isActive)
            isLoaded = true
        } catch is CancellationError {
            // A disappearing view is not a failed host. The next owner task can retry.
        } catch {
            guard generation == request else { return }
            errorMessage = error.localizedDescription
        }
    }

    private struct InvalidResponse: LocalizedError {
        var errorDescription: String? { String(localized: "session.new.bad_response") }
    }
}
