import Foundation
import TreeSitter

/// Validate original arguments: SwiftTreeSitter's parsed Predicate values lose
/// argument ordering, extra regex literals, and extra membership captures.
enum SyntaxPredicateValidator {
    static func validate(_ definition: TreeSitterSyntaxDefinition) throws {
        let bytes = Array(definition.highlightQuery.utf8)
        var errorOffset: UInt32 = 0
        var error = TSQueryErrorNone
        let query = bytes.withUnsafeBytes { buffer in
            ts_query_new(definition.language.tsLanguage,
                         buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                         UInt32(buffer.count), &errorOffset, &error)
        }
        guard let query else { throw SyntaxHighlightingError.unsupportedPredicate }
        defer { ts_query_delete(query) }

        // The wrapper does not expose its query pointer or original steps. Only
        // queries with predicates incur this second, short-lived compilation.
        for pattern in 0..<ts_query_pattern_count(query) {
            var count: UInt32 = 0
            let pointer = ts_query_predicates_for_pattern(query, pattern, &count)
            var steps: [TSQueryPredicateStep] = []
            for step in UnsafeBufferPointer(start: pointer, count: Int(count)) {
                if step.type == TSQueryPredicateStepTypeDone {
                    try validate(steps, query: query)
                    steps.removeAll(keepingCapacity: true)
                } else {
                    steps.append(step)
                }
            }
        }
    }

    private static func validate(_ steps: [TSQueryPredicateStep], query: OpaquePointer) throws {
        guard let first = steps.first, first.type == TSQueryPredicateStepTypeString else {
            throw SyntaxHighlightingError.unsupportedPredicate
        }
        var length: UInt32 = 0
        guard let name = ts_query_string_value_for_id(query, first.value_id, &length) else {
            throw SyntaxHighlightingError.unsupportedPredicate
        }
        let operation = String(decoding: UnsafeRawBufferPointer(start: name, count: Int(length)), as: UTF8.self)
        let arguments = steps.dropFirst()
        guard arguments.first?.type == TSQueryPredicateStepTypeCapture,
              arguments.dropFirst().allSatisfy({ $0.type == TSQueryPredicateStepTypeString }) else {
            throw SyntaxHighlightingError.unsupportedPredicate
        }
        switch operation {
        case "eq?", "not-eq?", "match?", "not-match?":
            guard arguments.count == 2 else { throw SyntaxHighlightingError.unsupportedPredicate }
        case "any-of?", "not-any-of?":
            // An empty set is valid: membership is false and nonmembership true.
            break
        default:
            // Includes capture equality, local-symbol predicates and directives
            // whose semantics the engine does not implement.
            throw SyntaxHighlightingError.unsupportedPredicate
        }
    }
}
