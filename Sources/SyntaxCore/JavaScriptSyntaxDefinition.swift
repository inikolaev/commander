import SwiftTreeSitter
import TreeSitterJavaScript

extension SyntaxLanguageDefinition {
    static let javascript = SyntaxLanguageDefinition(
        id: "javascript", fileExtensions: ["js", "jsx", "mjs", "cjs"],
        syntax: { .javascript }
    )
}

extension TreeSitterSyntaxDefinition {
    static let javascript = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_javascript()),
        highlightQuery: javascriptQuery + "\n" + jsxQuery,
        captures: codeCaptures
    )

    static let jsxQuery = """
    (jsx_opening_element (identifier) @type)
    (jsx_closing_element (identifier) @type)
    (jsx_self_closing_element (identifier) @type)
    """

    // TypeScript and TSX share these JavaScript node types and token names.
    static let javascriptQuery = """
    (identifier) @variable
    (property_identifier) @property
    (function_declaration name: (identifier) @function)
    (function_expression name: (identifier) @function)
    (method_definition name: (property_identifier) @function)
    (variable_declarator name: (identifier) @function value: [(arrow_function) (function_expression)])
    (call_expression function: (identifier) @function)
    (call_expression function: (member_expression property: (property_identifier) @function))
    (pair key: (string) @property)
    [(string) (template_string) (regex)] @string
    (template_substitution) @variable
    (number) @number
    [(true) (false) (null) (undefined)] @constant
    (comment) @comment
    ["async" "await" "break" "case" "catch" "class" "const" "continue"
     "debugger" "default" "delete" "do" "else" "export" "extends" "finally"
     "for" "from" "function" "if" "import" "in" "instanceof" "let" "new"
     "of" "return" "static" "switch" "throw" "try" "typeof" "var" "void"
     "while" "with" "yield"] @keyword
    """

}
