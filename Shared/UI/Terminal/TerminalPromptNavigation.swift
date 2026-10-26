import SwiftTerm
import SwiftUI

/// A selection retains its history identity through sheet dismissal/view updates.
struct TerminalPromptRequest: Identifiable {
    let id = UUID()
    let seq: Int
    let generation: Int
    /// The selected prompt's text, to recognise it after a host history rebuild.
    var text: String? = nil
}

/// Re-run a pending selection when its stream is created or presented.
struct TerminalPromptTaskKey: Hashable {
    let request: UUID?
    let stream: ObjectIdentifier?
    let presented: Bool
    let ready: Bool
}

/// The clicked prompt row's status (owner decision 2026-10-19): it replaces
/// the row's time label with a spinner while locating, then a short reason
/// for two seconds on failure. No popup, banner or focus change.
struct TerminalPromptRowStatus: Equatable {
    enum Kind: Equatable { case locating, absent, failed }

    let request: UUID
    let seq: Int
    var kind: Kind

    static let failureDuration: Duration = .seconds(2)
    /// A stream that never settles must not leave the spinner running.
    static let locatingLimit: Duration = .seconds(25)

    init(locating request: TerminalPromptRequest) {
        self.request = request.id
        seq = request.seq
        kind = .locating
    }

    /// The status after `outcome` for `request`; other requests leave it alone.
    func finishing(_ request: UUID, with outcome: TerminalPromptOutcome) -> TerminalPromptRowStatus? {
        guard request == self.request, kind == .locating else { return self }
        var next = self
        switch outcome {
        case .landed, .superseded: return nil
        case .absent: next.kind = .absent
        case .failed: next.kind = .failed
        }
        return next
    }
}

extension View {
    /// Clears a failure reason after two seconds; a request that never ends
    /// turns into a failure at the locating limit.
    func expiringPromptStatus(_ status: Binding<TerminalPromptRowStatus?>) -> some View {
        task(id: status.wrappedValue) {
            guard let current = status.wrappedValue else { return }
            let locating = current.kind == .locating
            try? await Task.sleep(for: locating ? TerminalPromptRowStatus.locatingLimit
                                                : TerminalPromptRowStatus.failureDuration)
            guard !Task.isCancelled, status.wrappedValue == current else { return }
            status.wrappedValue = locating ? current.finishing(current.request, with: .failed) : nil
        }
    }
}

/// The time-label replacement for a prompt row with a status.
struct TerminalPromptStatusLabel: View {
    let kind: TerminalPromptRowStatus.Kind

    var body: some View {
        HStack(spacing: 4) {
            if kind == .locating {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(title)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .locating: "terminal.prompt.locating"
        case .absent: "terminal.prompt.not_in_terminal"
        case .failed: "terminal.prompt.not_located"
        }
    }
}

extension TerminalView {
    /// Search the actual buffer, preserving wide glyphs at soft-wrap boundaries.
    /// SwiftTerm's native scroll API owns viewport movement. No input is sent.
    func revealPrompt(_ query: String, occurrence: Int = 0, total: Int = 1) -> Bool {
        guard let snapshot = terminalContentSnapshot(region: .history(maximumScrollbackRows: 10_000)) else { return false }
        let trimmed = snapshot.capturedRange.lowerBound
        var projection = ""
        var rowEnds: [(end: Int, row: Int)] = []
        var pendingSpace = false
        var utf16Length = 0
        for (index, line) in snapshot.rows.enumerated() {
            if index > 0 && !line.isWrapped { pendingSpace = true }
            // Translation skips only null cells belonging to a wide glyph;
            // it never removes the final translated character (CJK regression).
            let next = index + 1 < snapshot.rows.count ? snapshot.rows[index + 1] : nil
            let continues = next?.isWrapped == true
            var endColumn = line.cells.count
            // A wide glyph moved to the next row may leave one unused cell.
            // Exclude only that null padding, never a wide glyph's trailing half.
            if continues, let next, endColumn > 1, next.cells.first?.width == 2,
               line.cells[endColumn - 1].text == "\u{0}", line.cells[endColumn - 2].width != 2 {
                endColumn -= 1
            }
            let text = line.cells.prefix(endColumn).filter { $0.width != 0 }.map {
                $0.text.isEmpty || $0.text == "\u{0}" ? " " : $0.text
            }.joined()
            for character in text {
                if character.isWhitespace {
                    pendingSpace = true
                } else {
                    if pendingSpace && !projection.isEmpty { projection.append(" "); utf16Length += 1 }
                    pendingSpace = false
                    projection.append(character)
                    utf16Length += String(character).utf16.count
                }
            }
            rowEnds.append((utf16Length, line.absoluteRow - trimmed))
        }
        guard !query.isEmpty, total > 0, occurrence >= 0, occurrence < total else { return false }
        var matches: [Range<String.Index>] = []
        var start = projection.startIndex
        while start < projection.endIndex,
              let match = projection.range(of: query, options: .literal, range: start..<projection.endIndex) {
            matches.append(match)
            start = projection.index(after: match.lowerBound)
        }
        // A partial buffer cannot establish the selected occurrence's identity.
        guard matches.count == total else { return false }
        let match = matches[occurrence]
        let position = match.lowerBound.utf16Offset(in: projection)
        guard let target = rowEnds.first(where: { $0.end > position })?.row else { return false }
        // The owner requires the matched message at the top edge, not a
        // third-down reveal. SwiftTerm clamps only at the buffer's end.
        // The alternate buffer has no scrollback. Finding text below its
        // first row does not mean that the requested top-edge landing occurred.
        if snapshot.inputState.isAlternateBuffer { return target == 0 }
        scrollTo(row: max(0, target))
        return true
    }
}
