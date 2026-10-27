import Foundation

/// Presentation candidates only. The original source never changes; engines
/// validate candidates before a drawing replaces native selectable text.
nonisolated struct ChatDiagramBlock: Equatable, Sendable {
    enum Kind: String, Sendable { case mermaid, plantuml }
    let kind: Kind
    let source: String
    let original: String
    let codeIdentity: Int?
    let progressive: Bool

    static func candidates(source: String, parsed: AttributedString) -> [Self] {
        guard source.utf8.count <= 16_384 else { return [] }
        var result: [Self] = []
        var seen = Set<Int>()
        for run in parsed.runs {
            guard let intent = run.presentationIntent,
                  !intent.components.contains(where: { if case .blockQuote = $0.kind { return true }; return false })
            else { continue }
            for component in intent.components {
                guard case .codeBlock(let label) = component.kind,
                      seen.insert(component.identity).inserted,
                      let position = run.markdownSourcePosition,
                      let range = Range(position, in: source) else { continue }
                let original = String(source[range])
                guard closedFence(original) else { continue }
                let code = parsed.runs.filter { candidate in
                    candidate.presentationIntent?.components.contains(where: { $0.identity == component.identity }) == true
                }.map { String(parsed[$0.range].characters) }.joined()
                if let kind = classify(label: label ?? "", source: code) {
                    result.append(Self(kind: kind, source: code, original: original,
                                       codeIdentity: component.identity, progressive: false))
                }
            }
        }
        if result.isEmpty, !source.contains("```"), !source.contains("~~~"),
           let kind = infer(source) {
            result.append(Self(kind: kind, source: source, original: source, codeIdentity: nil,
                               progressive: kind == .mermaid))
        }
        return result
    }

    static func closedFence(_ source: String) -> Bool {
        let lines = source.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return false }
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        guard let marker = first.first, marker == "`" || marker == "~" else { return false }
        let count = first.prefix(while: { $0 == marker }).count
        let last = (lines.last ?? "").trimmingCharacters(in: .whitespaces)
        return count >= 3 && last.count >= count && last.allSatisfy { $0 == marker }
    }

    static func classify(label: String, source: String) -> Kind? {
        switch label.lowercased().trimmingCharacters(in: .whitespaces) {
        case "mermaid", "mmd": .mermaid
        case "plantuml", "puml", "uml": .plantuml
        case "": infer(source)
        default: nil
        }
    }

    static func infer(_ source: String) -> Kind? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return nil }
        if lines.first?.lowercased() == "@startuml", lines.last?.lowercased() == "@enduml" { return .plantuml }
        let meaningful = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix("%%") })
        guard let head = meaningful.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        let opening = #"^(?:(?:flowchart|graph)(?:\s+(?:TB|TD|BT|LR|RL))?|sequenceDiagram|classDiagram(?:-v2)?|stateDiagram(?:-v2)?|erDiagram|gantt|pie(?:\s+(?:showData|title\b.*))?|mindmap|journey|timeline|gitGraph|quadrantChart|requirementDiagram|sankey(?:-beta)?|xychart(?:-beta)?|block(?:-beta)?|kanban|architecture(?:-beta)?|packet(?:-beta)?|radar(?:-beta)?|treemap(?:-beta)?|C4(?:Context|Container|Component|Dynamic|Deployment))\s*;?$"#
        guard head.range(of: opening, options: .regularExpression) != nil else { return nil }
        if ["mindmap", "journey", "timeline", "kanban", "treemap"].contains(where: { head.hasPrefix($0) }) {
            guard meaningful.dropFirst().allSatisfy({ line in
                line.first?.isWhitespace == true && !line.trimmingCharacters(in: .whitespaces).isEmpty
            }) else { return nil }
        }
        return .mermaid
    }
}
