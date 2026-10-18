import SwiftTreeSitter
import TreeSitterSwift

extension SyntaxLanguageDefinition {
    static let swift = SyntaxLanguageDefinition(
        id: "swift", fileExtensions: ["swift"],
        syntax: { .swift }
    )
}

extension TreeSitterSyntaxDefinition {
    static let swift = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_swift()),
        highlightQuery: #"""
        (simple_identifier) @variable
        (type_identifier) @type
        (function_declaration name: (simple_identifier) @function)
        (call_expression (simple_identifier) @function)
        (call_expression (navigation_expression (navigation_suffix (simple_identifier) @function)))
        (navigation_suffix (simple_identifier) @property)
        [(comment) (multiline_comment)] @comment
        [(line_str_text) (multi_line_str_text) (raw_str_part) (raw_str_end_part) (str_escaped_char)] @string
        ["\"" "\"\"\""] @string
        [(integer_literal) (hex_literal) (oct_literal) (bin_literal) (real_literal)] @number
        [(boolean_literal) (nil_literal)] @constant
        ["func" "let" "var" "struct" "class" "enum" "protocol" "extension" "import"
         "return" "if" "guard" "for" "in" "while" "async" "await" "break" "continue"] @keyword
        [(throws) (throw_keyword) (catch_keyword) (else) (where_keyword)
         (visibility_modifier) (function_modifier)] @keyword
        """#,
        captures: codeCaptures
    )
}
