import SwiftTreeSitter
import TreeSitterGo

extension SyntaxLanguageDefinition {
    static let go = SyntaxLanguageDefinition(
        id: "go", fileExtensions: ["go"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .go) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let go = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_go()),
        highlightQuery: #"""
        (identifier) @variable
        (type_identifier) @type
        (field_identifier) @property
        (function_declaration name: (identifier) @function)
        (method_declaration name: (field_identifier) @function)
        (call_expression function: (identifier) @function)
        (call_expression function: (selector_expression field: (field_identifier) @function))
        [(interpreted_string_literal) (raw_string_literal) (rune_literal)] @string
        [(int_literal) (float_literal) (imaginary_literal)] @number
        [(true) (false) (nil) (iota)] @constant
        (comment) @comment
        ["break" "case" "chan" "const" "continue" "default" "defer" "else" "fallthrough"
         "for" "func" "go" "goto" "if" "import" "interface" "map" "package" "range"
         "return" "select" "struct" "switch" "type" "var"] @keyword
        """#,
        captures: codeCaptures
    )
}
