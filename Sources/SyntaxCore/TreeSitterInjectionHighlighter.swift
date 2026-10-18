import Foundation
import SwiftTreeSitter

/// Capture source regions as `injection.content`. Language selection belongs to
/// the host definition, so composition never needs to know about HTML or CSS.
struct TreeSitterSyntaxInjection: Sendable {
    let query: String
    let resolveLanguage: @Sendable (Node, Data, SyntaxRegistry) -> TreeSitterSyntaxDefinition?
    var excludingChildTypes: Set<String> = []
    var defaultKind: SyntaxKind? = nil

    init(query: String, language: @escaping @Sendable (Node, Data) -> TreeSitterSyntaxDefinition?,
         excludingChildTypes: Set<String> = [], defaultKind: SyntaxKind? = nil) {
        self.query = query
        self.resolveLanguage = { node, source, _ in language(node, source) }
        self.excludingChildTypes = excludingChildTypes
        self.defaultKind = defaultKind
    }

    init(query: String, languageAlias: @escaping @Sendable (Node, Data) -> String?,
         excludingChildTypes: Set<String> = [], defaultKind: SyntaxKind? = nil) {
        self.query = query
        self.resolveLanguage = { node, source, registry in
            languageAlias(node, source).flatMap { registry.syntaxDefinition(forAlias: $0) }
        }
        self.excludingChildTypes = excludingChildTypes
        self.defaultKind = defaultKind
    }

}

enum TreeSitterInjectionHighlighter {
    static let maximumDepth = 8

    static func compose(captures: [SyntaxCapture], source: Data, tree: MutableTree, language: Language,
                        injections: [TreeSitterSyntaxInjection], depth: Int, includedRanges: [TSRange]? = nil, registry: SyntaxRegistry = .viewer) -> [SyntaxCapture] {
        guard !injections.isEmpty, depth < maximumDepth else { return captures }
        // Normalize each layer independently. Embedded tokens win over host
        // tokens regardless of the host language's internal capture priorities.
        var result = SyntaxSpanNormalizer.normalize(captures).map {
            SyntaxCapture(span: $0, priority: 0)
        }
        var visited: Set<Range<Int>> = []
        for injection in injections {
            // Injection queries deliberately contain only structural patterns.
            // Selection logic lives in the typed resolver, not #set! directives.
            guard let query = try? Query(language: language, data: Data(injection.query.utf8)),
                  !query.hasPredicates else { continue }
            let cursor = query.execute(in: tree)
            while let match = cursor.next() {
                for capture in match.captures where capture.name == "injection.content" {
                    let bytes = capture.node.byteRange
                    let range = Int(bytes.lowerBound)..<Int(bytes.upperBound)
                    guard !range.isEmpty, range.upperBound <= source.count,
                          !visited.contains(range),
                          let definition = injection.resolveLanguage(capture.node, source, registry) else { continue }
                    let included = SyntaxInjectionRanges.included(in: capture.node, excluding: injection.excludingChildTypes, inherited: includedRanges)
                    guard let child = try? TreeSitterSyntaxHighlighter(
                            source: source.subdata(in: range), definition: definition,
                            injectionDepth: depth + 1, includedRanges: included, registry: registry) else { continue }
                    visited.insert(range)
                    if let kind = injection.defaultKind {
                        let regions = included?.map { Int($0.bytes.lowerBound)..<Int($0.bytes.upperBound) } ?? [0..<range.count]
                        for region in regions {
                            result.append(SyntaxCapture(span: SyntaxHighlightSpan(
                                byteRange: (range.lowerBound + region.lowerBound)..<(range.lowerBound + region.upperBound),
                                kind: kind), priority: 1))
                        }
                    }
                    for span in child.highlights(in: 0..<range.count) {
                        result.append(SyntaxCapture(span: SyntaxHighlightSpan(
                            byteRange: (range.lowerBound + span.byteRange.lowerBound)..<(range.lowerBound + span.byteRange.upperBound),
                            kind: span.kind), priority: 2))
                    }
                }
            }
        }
        return result
    }
}
