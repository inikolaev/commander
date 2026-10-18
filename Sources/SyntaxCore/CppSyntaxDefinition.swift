import SwiftTreeSitter
import TreeSitterCPP

extension SyntaxLanguageDefinition {
    static let cpp = SyntaxLanguageDefinition(
        id: "cpp", fileExtensions: ["cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "tpp"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .cpp) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let cpp = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_cpp()),
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
        (call_expression function: (qualified_identifier name: (identifier) @function))
        (function_declarator declarator: (qualified_identifier name: (identifier) @function))
        (function_declarator declarator: (field_identifier) @function)
        (raw_string_literal) @string
        (auto) @type
        ["catch" "class" "constexpr" "delete" "explicit" "friend" "namespace" "new"
         "private" "protected" "public" "template" "throw" "try" "typename" "using"
         "virtual" "override" "noexcept" "concept" "requires" "co_await" "co_return" "co_yield"] @keyword
        """#,
        captures: codeCaptures
    )
}
