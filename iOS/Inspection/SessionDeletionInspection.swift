#if DEBUG && os(iOS)
import SwiftUI

/// Fictional rows render the production interaction without a host or history API.
struct SessionDeletionInspection: View {
    @State private var tick = 0
    @State private var deletedKeys: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                ForEach((0..<24).filter { !deletedKeys.contains("inspection:\($0)") }, id: \.self) { index in
                    let session = SessionSummary(
                        key: "inspection:\(index)", runtime: "codex", title: "Session \(index)",
                        cwd: "/fixture", mtime: Double(tick), live: false
                    )
                    SessionListItem(session: session, onPin: {}, onStop: {}, onDelete: {
                        deletedKeys.insert($0.key)
                    })
                }
            }
            .listStyle(.plain)
            .navigationTitle("Deletion inspection")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    tick += 1
                }
            }
        }
    }
}
#endif
