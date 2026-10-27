import Foundation
import XCTest
@testable import Corral

final class ChatDiagramBlockTests: XCTestCase {
    private func candidates(_ source: String) throws -> [ChatDiagramBlock] {
        var options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        options.appliesSourcePositionAttributes = true
        return ChatDiagramBlock.candidates(source: source, parsed: try AttributedString(markdown: source, options: options))
    }

    func testExplicitAliasesAndPrecedence() throws {
        for label in ["mermaid", "mmd", "MERMAID"] {
            XCTAssertEqual(try candidates("```\(label)\nflowchart LR\nA-->B\n```").first?.kind, .mermaid)
        }
        for label in ["plantuml", "puml", "uml"] {
            XCTAssertEqual(try candidates("```\(label)\nAlice -> Bob\n```").first?.kind, .plantuml)
        }
        XCTAssertEqual(ChatDiagramBlock.classify(label: "mermaid", source: "@startuml\nA->B\n@enduml"), .mermaid)
        XCTAssertNil(ChatDiagramBlock.classify(label: "swift", source: "flowchart LR\nA-->B"))
    }

    func testUnclosedAndMismatchedFencesStaySource() throws {
        for source in ["```mermaid\nflowchart LR\nA-->B", "````mermaid\nflowchart LR\nA-->B\n```", "~~~mermaid\nflowchart LR\nA-->B\n```"] {
            XCTAssertTrue(try candidates(source).isEmpty)
        }
    }

    func testSourceFencesUnicodeCRLFAndOrder() throws {
        let first = "````mermaid\r\nflowchart LR\r\nA[中文👨‍👩‍👧‍👦]-->B\r\n````"
        let second = "~~~puml\n@startuml\nAlice -> Bob : 好\n@enduml\n~~~"
        let blocks = try candidates("Before\n\n\(first)\n\nBetween\n\n\(second)\n\nAfter")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.original, first)
        XCTAssertEqual(blocks.last?.original, second)
        XCTAssertNotEqual(blocks.first?.codeIdentity, blocks.last?.codeIdentity)
    }

    func testQuotesAndInlineCodeDoNotRender() throws {
        XCTAssertTrue(try candidates("> ```mermaid\n> flowchart LR\n> A-->B\n> ```").isEmpty)
        XCTAssertTrue(try candidates("Use `sequenceDiagram` for a sequence.").isEmpty)
    }

    func testNestedListKeepsNativeContext() throws {
        let blocks = try candidates("- Example\n\n  ~~~puml\n  @startuml\n  Alice -> Bob\n  @enduml\n  ~~~")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.source.trimmingCharacters(in: .whitespacesAndNewlines), "@startuml\nAlice -> Bob\n@enduml")
    }

    func testUnlabelledAndWholeMessage() throws {
        XCTAssertEqual(try candidates("```\nflowchart LR\nA-->B\n```").first?.kind, .mermaid)
        XCTAssertEqual(try candidates("@startuml\nAlice -> Bob\n@enduml").first?.kind, .plantuml)
        XCTAssertEqual(try candidates("flowchart LR\nA-->B").first?.progressive, true)
        XCTAssertTrue(try candidates("Here is the flow:\nflowchart LR\nA-->B").isEmpty)
        XCTAssertTrue(try candidates("timeline\nThis is ordinary prose.").isEmpty)
        XCTAssertEqual(try candidates("mindmap\n  root((中文))\n    Child").first?.kind, .mermaid)
    }

    func testBudget() throws {
        let source = "```mermaid\nflowchart LR\n" + String(repeating: "A-->B\n", count: 3000) + "```"
        XCTAssertTrue(try candidates(source).isEmpty)
    }
}
