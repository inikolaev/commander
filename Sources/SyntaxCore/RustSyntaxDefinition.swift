import SwiftTreeSitter
import TreeSitterRust

extension SyntaxLanguageDefinition {
    static let rust = SyntaxLanguageDefinition(
        id: "rust", fileExtensions: ["rs"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .rust) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let rust = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_rust()),
        highlightQuery: #"""
        (identifier) @variable
        [(type_identifier) (primitive_type)] @type
        (field_identifier) @property
        (function_item name: (identifier) @function)
        (function_signature_item name: (identifier) @function)
        (call_expression function: (identifier) @function)
        (call_expression function: (field_expression field: (field_identifier) @function))
        (call_expression function: (scoped_identifier name: (identifier) @function))
        (macro_invocation macro: (identifier) @function)
        [(line_comment) (block_comment)] @comment
        [(string_literal) (raw_string_literal) (char_literal)] @string
        [(integer_literal) (float_literal)] @number
        (boolean_literal) @constant
        (mutable_specifier) @keyword
        ["as" "async" "await" "break" "const" "continue" "dyn" "else" "enum" "extern"
         "fn" "for" "if" "impl" "in" "let" "loop" "match" "mod" "move" "pub" "ref"
         "return" "static" "struct" "trait" "type" "unsafe" "use" "where" "while"] @keyword
        """#,
        captures: codeCaptures
    )
}
