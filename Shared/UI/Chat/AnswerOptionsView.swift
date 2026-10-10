import SwiftUI

/// One compact native surface for answering the latest pending agent request.
struct AnswerOptionsView: View {
    @Environment(\.interfaceScale) private var interfaceScale
    let prompts: [SessionPrompt]
    let isConnected: Bool
    var isBusy = false
    let submissionState: NativeQuestionSubmissionState?
    let onSubmit: (String, [NativeQuestionAnswer]) -> Void

    @State private var selectedOptionIDs: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]
    @State private var expandedQuestionIDs: Set<String> = []
    @FocusState private var focusedQuestionID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var requestID: String { prompts.first?.requestID ?? "" }
    private var requestPrompts: [SessionPrompt] {
        prompts.filter { $0.requestID == requestID }
    }
    private var questionIDs: [String] { requestPrompts.map(\.questionID) }
    private var isSubmitting: Bool { currentStatus == .submitting }
    private var currentStatus: NativeQuestionSubmissionStatus? {
        guard submissionState?.requestID == requestID else { return nil }
        return submissionState?.status
    }
    private var canSubmit: Bool {
        isConnected && !isBusy && !isSubmitting && requestID.isEmpty == false
            && currentStatus != .delivered
            && !isTerminalRejection(currentStatus)
            && requestPrompts.allSatisfy(isAnswered)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md * interfaceScale) {
            HStack(spacing: Space.sm * interfaceScale) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                Text("chat.question.title")
                    .sessionFont(.sectionHeader)
                    .foregroundStyle(.primary)
                Spacer(minLength: Space.xs * interfaceScale)
                if isSubmitting {
                    ProgressView().interfaceControlSize(.small)
                }
            }

            ForEach(Array(requestPrompts.enumerated()), id: \.element.questionID) { index, question in
                questionRow(question, index: index)
            }

            statusMessage

            Button(action: submit) {
                HStack(spacing: Space.xs * interfaceScale) {
                    if isSubmitting { ProgressView().interfaceControlSize(.small) }
                    Text(submitTitle)
                        .sessionFont(.toolTitle)
                }
                .interfaceFrame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .foregroundStyle(Palette.onAccent)
            .disabled(!canSubmit)
            .accessibilityHint(Text("chat.question.submit_hint"))
        }
        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
        .interfacePadding(Space.md)
        .background(
            Palette.assistantBubble,
            in: RoundedRectangle(cornerRadius: Radius.lg * interfaceScale, style: .continuous)
        )
        .onAppear(perform: seedDisclosureState)
        .onChange(of: requestID) { _, _ in
            selectedOptionIDs.removeAll()
            customAnswers.removeAll()
            expandedQuestionIDs.removeAll()
            seedDisclosureState()
        }
        .onChange(of: questionIDs) { _, ids in
            let valid = Set(ids)
            selectedOptionIDs = selectedOptionIDs.filter { valid.contains($0.key) }
            customAnswers = customAnswers.filter { valid.contains($0.key) }
            expandedQuestionIDs.formIntersection(valid)
        }
    }

    @ViewBuilder
    private func questionRow(_ question: SessionPrompt, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Space.sm * interfaceScale) {
            Button {
                toggleDisclosure(question.questionID)
            } label: {
                HStack(alignment: .top, spacing: Space.sm * interfaceScale) {
                    VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
                        if requestPrompts.count > 1 || question.header?.isEmpty == false {
                            HStack(spacing: Space.xs * interfaceScale) {
                                if requestPrompts.count > 1 {
                                    Text("\(index + 1)/\(requestPrompts.count)")
                                        .monospacedDigit()
                                }
                                if let header = question.header, !header.isEmpty {
                                    Text(header)
                                }
                            }
                            .sessionFont(.toolMeta)
                            .foregroundStyle(.secondary)
                        }
                        Text(question.prompt ?? question.summary ?? question.detail ?? question.name ?? String(localized: "chat.question.generic"))
                            .sessionFont(.bubbleBody)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                        if !expandedQuestionIDs.contains(question.questionID),
                           let summary = answerSummary(question) {
                            Label(summary, systemImage: "checkmark")
                                .sessionFont(.toolMeta)
                                .foregroundStyle(Palette.accent)
                                .lineLimit(2)
                        }
                    }
                    Image(systemName: expandedQuestionIDs.contains(question.questionID) ? "chevron.up" : "chevron.down")
                        .interfaceFont(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .interfacePadding(.top, Space.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .interfaceFrame(minHeight: TouchTarget.minimum, alignment: .leading)
            .accessibilityHint(Text(expandedQuestionIDs.contains(question.questionID)
                ? "chat.question.collapse_hint"
                : "chat.question.expand_hint"))

            if expandedQuestionIDs.contains(question.questionID) {
                answerList(question)
            }
        }
        .interfacePadding(.top, index == 0 ? 0 : Space.xs)
    }

    /// Choices and the typed answer share one inset group with hairline
    /// separators, like a Settings section, instead of a stack of tall cards.
    private func answerList(_ question: SessionPrompt) -> some View {
        let options = displayOptions(for: question)
        return VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index > 0 { rowDivider }
                optionRow(option, question: question)
            }
            if question.allowCustom {
                if !options.isEmpty { rowDivider }
                customAnswerRow(question)
            }
        }
        .background(
            Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Radius.md * interfaceScale, style: .continuous)
        )
        .disabled(isBusy || isSubmitting || currentStatus == .delivered || isTerminalRejection(currentStatus))
    }

    private var rowDivider: some View {
        Divider().interfacePadding(.leading, Space.md + Self.markWidth + Space.sm)
    }

    private static let markWidth: CGFloat = 22

    private func optionRow(_ option: SessionPromptOption, question: SessionPrompt) -> some View {
        let selected = selectedOptionIDs[question.questionID, default: []].contains(option.id)
        return Button {
            toggle(option.id, for: question)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm * interfaceScale) {
                Image(systemName: selectionSymbol(selected: selected, multiple: question.multiSelect))
                    .foregroundStyle(selected ? Palette.accent : Color.secondary)
                    .interfaceFrame(width: Self.markWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2 * interfaceScale) {
                    Text(option.label)
                        .sessionFont(.bubbleBody)
                        .foregroundStyle(.primary)
                        .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .sessionFont(.toolMeta)
                            .foregroundStyle(.secondary)
                            .interfaceFrame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .interfacePadding(.horizontal, Space.md)
            .interfacePadding(.vertical, Space.sm + 2)
            .interfaceFrame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(option.label))
        .accessibilityValue(Text(selected ? "chat.question.selected" : "chat.question.not_selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func customAnswerRow(_ question: SessionPrompt) -> some View {
        let placeholder: LocalizedStringKey = question.customNeedsChoice
            ? "chat.question.note_placeholder"
            : "chat.question.custom_placeholder"
        // Center, not baseline: a vertical-axis TextField reports no usable first baseline.
        return HStack(alignment: .center, spacing: Space.sm * interfaceScale) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
                .interfaceFrame(width: Self.markWidth)
                .accessibilityHidden(true)
            Group {
                if question.isSecret {
                    SecureField(placeholder, text: answerBinding(for: question))
                } else {
                    TextField(placeholder, text: answerBinding(for: question), axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .textFieldStyle(.plain)
            .sessionFont(.bubbleBody)
            .focused($focusedQuestionID, equals: question.questionID)
            .submitLabel(.done)
            .accessibilityHint(Text("chat.question.custom_hint"))
        }
        .interfacePadding(.horizontal, Space.md)
        .interfacePadding(.vertical, Space.sm + 2)
        .interfaceFrame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focusedQuestionID = question.questionID }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch currentStatus {
        case .delivered:
            Label("chat.question.sent", systemImage: "checkmark.circle.fill")
                .sessionFont(.toolMeta)
                .foregroundStyle(.secondary)
        case .stale(let detail):
            statusLabel("chat.question.stale", detail: detail, symbol: "clock")
        case .unavailable(let detail):
            statusLabel("chat.question.unavailable", detail: detail, symbol: "exclamationmark.triangle")
        case .failed(let detail):
            statusLabel("chat.question.failed", detail: detail, symbol: "exclamationmark.triangle")
        case .submitting, nil:
            EmptyView()
        }
    }

    private var submitTitle: LocalizedStringKey {
        if isSubmitting { return "chat.question.submitting" }
        if currentStatus == .delivered { return "chat.question.sent" }
        if case .failed = currentStatus { return "chat.question.retry" }
        return "chat.question.submit"
    }

    private func statusLabel(_ key: LocalizedStringKey, detail: String?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs * interfaceScale) {
            Label(key, systemImage: symbol)
                .sessionFont(.toolMeta)
                .foregroundStyle(.secondary)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .sessionFont(.toolMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func displayOptions(for question: SessionPrompt) -> [SessionPromptOption] {
        if !question.optionDetails.isEmpty { return question.optionDetails }
        return question.options.enumerated().map { index, label in
            SessionPromptOption(id: String(index), label: label, description: nil)
        }
    }

    private func answerBinding(for question: SessionPrompt) -> Binding<String> {
        Binding(
            get: { customAnswers[question.questionID, default: ""] },
            set: { customAnswers[question.questionID] = $0 }
        )
    }

    private func toggle(_ optionID: String, for question: SessionPrompt) {
        let previous = selectedOptionIDs[question.questionID, default: []]
        let next = NativeQuestionSelection.toggled(
            optionID,
            in: selectedOptionIDs[question.questionID, default: []],
            allowsMultiple: question.multiSelect
        )
        selectedOptionIDs[question.questionID] = next
        if next != previous { HapticFeedback.shared.emit(.selection) }
        // A single choice is complete once picked: fold it and open the next open question.
        let typed = customAnswers[question.questionID, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.multiSelect, !next.isEmpty, typed.isEmpty,
              let nextOpen = requestPrompts.first(where: { !isAnswered($0) }) else { return }
        withAnimation(reduceMotion ? nil : .snappy) {
            expandedQuestionIDs.remove(question.questionID)
            expandedQuestionIDs.insert(nextOpen.questionID)
        }
    }

    private func isAnswered(_ question: SessionPrompt) -> Bool {
        NativeQuestionSelection.isAnswered(
            selected: selectedOptionIDs[question.questionID, default: []],
            typed: customAnswers[question.questionID, default: ""],
            customNeedsChoice: question.customNeedsChoice
        )
    }

    private func answerSummary(_ question: SessionPrompt) -> String? {
        let chosen = displayOptions(for: question)
            .filter { selectedOptionIDs[question.questionID, default: []].contains($0.id) }
            .map(\.label)
        let typed = customAnswers[question.questionID, default: ""]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = chosen + (typed.isEmpty || question.isSecret ? [] : [typed])
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func selectionSymbol(selected: Bool, multiple: Bool) -> String {
        switch (multiple, selected) {
        case (true, true): "checkmark.square.fill"
        case (true, false): "square"
        case (false, true): "checkmark.circle.fill"
        case (false, false): "circle"
        }
    }

    private func toggleDisclosure(_ questionID: String) {
        if expandedQuestionIDs.contains(questionID) {
            expandedQuestionIDs.remove(questionID)
        } else {
            expandedQuestionIDs.insert(questionID)
        }
    }

    private func seedDisclosureState() {
        guard expandedQuestionIDs.isEmpty, let firstID = requestPrompts.first?.questionID else { return }
        expandedQuestionIDs.insert(firstID)
    }

    private func submit() {
        guard canSubmit else { return }
        focusedQuestionID = nil
        let answers = requestPrompts.map { question in
            NativeQuestionAnswer(
                questionID: question.questionID,
                selected: displayOptions(for: question)
                    .filter { selectedOptionIDs[question.questionID, default: []].contains($0.id) }
                    .map(\.id),
                text: customAnswers[question.questionID, default: ""]
            )
        }
        onSubmit(requestID, answers)
    }

    private func isTerminalRejection(_ status: NativeQuestionSubmissionStatus?) -> Bool {
        switch status {
        case .stale, .unavailable: true
        default: false
        }
    }
}
