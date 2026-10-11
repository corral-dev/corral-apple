import XCTest
@testable import Corral

@MainActor
final class NativeQuestionTests: XCTestCase {
    func testPromptDecodesCompleteNativeQuestionContract() throws {
        let response = try RemoteJSONDecoder.decode(
            SessionPromptsResponse.self,
            from: [
                "prompts": [[
                    "id": "legacy-id",
                    "request_id": "request-1",
                    "question_id": "question-1",
                    "prompt": "Which approach?",
                    "summary": "Legacy summary",
                    "options": ["Keep", "Replace"],
                    "multi_select": true,
                    "allow_custom": true,
                    "is_secret": false,
                    "option_details": [
                        ["id": "0", "label": "Keep", "description": "Preserve the current data"],
                        ["id": "1", "label": "Replace"]
                    ]
                ]]
            ]
        )

        let prompt = try XCTUnwrap(response.prompts.first)
        XCTAssertEqual(prompt.id, "legacy-id")
        XCTAssertEqual(prompt.requestID, "request-1")
        XCTAssertEqual(prompt.questionID, "question-1")
        XCTAssertEqual(prompt.prompt, "Which approach?")
        XCTAssertTrue(prompt.multiSelect)
        XCTAssertTrue(prompt.allowCustom)
        XCTAssertFalse(prompt.isSecret)
        XCTAssertEqual(prompt.optionDetails.map(\.id), ["0", "1"])
        XCTAssertEqual(prompt.optionDetails.first?.description, "Preserve the current data")
    }

    func testLegacyPromptDefaultsToSingleChoiceWithoutFreeform() throws {
        let prompt = try RemoteJSONDecoder.decode(
            SessionPrompt.self,
            from: ["id": "old", "options": ["Continue"]]
        )

        XCTAssertEqual(prompt.requestID, "old")
        XCTAssertEqual(prompt.questionID, "old")
        XCTAssertFalse(prompt.multiSelect)
        XCTAssertFalse(prompt.allowCustom)
        XCTAssertFalse(prompt.isSecret)
        XCTAssertFalse(prompt.blocksInput)
        XCTAssertEqual(prompt.options, ["Continue"])
        XCTAssertTrue(prompt.optionDetails.isEmpty)
    }

    func testBlocksInputDecodesAndDefaultsAbsent() throws {
        let blocking = try RemoteJSONDecoder.decode(
            SessionPrompt.self,
            from: ["id": "q", "options": ["A"], "blocks_input": true]
        )
        XCTAssertTrue(blocking.blocksInput)

        let older = try RemoteJSONDecoder.decode(
            SessionPrompt.self,
            from: ["id": "q", "options": ["A"]]
        )
        XCTAssertFalse(older.blocksInput)

        let answered = NativeQuestionSubmissionState(requestID: "req-1", status: .delivered)
        XCTAssertTrue(PendingQuestionGate.blocksInput(
            [SessionPrompt(id: "p", name: nil, summary: nil, detail: nil, options: ["A"],
                           requestID: "req-1", blocksInput: true)],
            submission: nil
        ))
        XCTAssertFalse(PendingQuestionGate.blocksInput(
            [SessionPrompt(id: "p", name: nil, summary: nil, detail: nil, options: ["A"],
                           requestID: "req-1", blocksInput: true)],
            submission: answered
        ))
    }

    func testPreviewQuestionNeedsChoiceBeforeTypedNoteCounts() throws {
        let prompt = try RemoteJSONDecoder.decode(
            SessionPrompt.self,
            from: ["id": "q", "options": ["A"], "allow_custom": true, "custom_needs_choice": true]
        )
        XCTAssertTrue(prompt.customNeedsChoice)
        XCTAssertFalse(NativeQuestionSelection.isAnswered(selected: [], typed: "other", customNeedsChoice: true))
        XCTAssertTrue(NativeQuestionSelection.isAnswered(selected: ["0"], typed: "other", customNeedsChoice: true))
        XCTAssertTrue(NativeQuestionSelection.isAnswered(selected: [], typed: "other", customNeedsChoice: false))
        XCTAssertFalse(NativeQuestionSelection.isAnswered(selected: [], typed: "  ", customNeedsChoice: false))
    }

    func testChoiceSelectionFollowsPerQuestionMode() {
        XCTAssertEqual(
            NativeQuestionSelection.toggled("b", in: ["a"], allowsMultiple: false),
            ["b"]
        )
        XCTAssertEqual(
            NativeQuestionSelection.toggled("b", in: ["a"], allowsMultiple: true),
            ["a", "b"]
        )
        XCTAssertEqual(
            NativeQuestionSelection.toggled("a", in: ["a"], allowsMultiple: true),
            []
        )
    }

    func testAnswerWireValueKeepsSelectedChoicesAndTypedTextSeparate() {
        let answer = NativeQuestionAnswer(
            questionID: "question-1",
            selected: ["0"],
            text: "With a note"
        )

        XCTAssertEqual(
            answer.wireValue() as NSDictionary,
            ["question_id": "question-1", "selected": ["0"], "text": "With a note"] as NSDictionary
        )
    }

    func testResultStatusDistinguishesDeliveryFromStaleAndUnavailable() throws {
        for (status, expected) in [
            ("delivered", NativeQuestionAnswerResult.Status.delivered),
            ("stale", .stale),
            ("unavailable", .unavailable)
        ] {
            let result = try RemoteJSONDecoder.decode(
                NativeQuestionAnswerResult.self,
                from: ["status": status]
            )
            XCTAssertEqual(result.status, expected)
        }
    }
}
