import SwiftTreeSitter
import TreeSitterKotlin

extension SyntaxLanguageDefinition {
    static let kotlin = SyntaxLanguageDefinition(
        id: "kotlin", fileExtensions: ["kt", "kts"],
        syntax: { .kotlin }
    )
}

extension TreeSitterSyntaxDefinition {
    static let kotlin = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_kotlin()),
        highlightQuery: #"""
        (simple_identifier) @variable
        (type_identifier) @type
        (function_declaration . (simple_identifier) @function)
        (call_expression . (simple_identifier) @function)
        (call_expression (navigation_expression (navigation_suffix (simple_identifier) @function) .))
        (navigation_suffix (simple_identifier) @property)
        [(line_comment) (multiline_comment) (shebang_line)] @comment
        [(real_literal) (integer_literal) (long_literal) (hex_literal) (bin_literal) (unsigned_literal)] @number
        [(boolean_literal) "null"] @constant
        [(character_literal) (string_literal)] @string
        [(interpolated_identifier) (interpolated_expression)] @variable
        ["val" "var" "enum" "class" "object" "interface" "fun" "if" "else" "when"
         "for" "do" "while" "try" "catch" "throw" "finally" "return" "import" "package"] @keyword
        [(visibility_modifier) (inheritance_modifier) (function_modifier)] @keyword
        """#,
        captures: codeCaptures
    )
}
