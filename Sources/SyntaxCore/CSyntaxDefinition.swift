import SwiftTreeSitter
import TreeSitterC

extension SyntaxLanguageDefinition {
    static let c = SyntaxLanguageDefinition(
        id: "c", fileExtensions: ["c", "h"],
        syntax: { .c }
    )
}

extension TreeSitterSyntaxDefinition {
    static let c = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_c()),
        highlightQuery: #"""
        (identifier) @variable
        [(type_identifier) (primitive_type) (sized_type_specifier)] @type
        (field_identifier) @property
        (call_expression function: (identifier) @function)
        (call_expression function: (field_expression field: (field_identifier) @function))
        (function_declarator declarator: (identifier) @function)
        [(string_literal) (system_lib_string) (char_literal)] @string
        (number_literal) @number
        [(null) (true) (false)] @constant
        (comment) @comment
        ["break" "case" "const" "continue" "default" "do" "else" "enum" "extern"
         "for" "if" "inline" "return" "sizeof" "static" "struct" "switch" "typedef"
         "union" "volatile" "while" "#include" "#define" "#if" "#ifdef" "#ifndef" "#endif"] @keyword
        """#,
        captures: codeCaptures
    )
}
