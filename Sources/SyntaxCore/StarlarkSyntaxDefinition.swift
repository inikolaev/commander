import SwiftTreeSitter
import TreeSitterStarlark

extension SyntaxLanguageDefinition {
    static let starlark = SyntaxLanguageDefinition(
        id: "starlark", fileExtensions: ["bzl", "bazel"], fileNames: ["BUILD", "WORKSPACE"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .starlark) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let starlark = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_starlark()),
        highlightQuery: #"""
        (identifier) @variable
        (function_definition name: (identifier) @function)
        (call function: (identifier) @function)
        (call function: (attribute attribute: (identifier) @function))
        (attribute attribute: (identifier) @property)
        (keyword_argument name: (identifier) @property)
        [(integer) (float)] @number
        [(true) (false) (none)] @constant
        (string) @string
        (comment) @comment
        ["def" "return" "if" "elif" "else" "for" "in" "and" "or" "not" "lambda" "pass" "break" "continue"] @keyword
        """#,
        captures: codeCaptures
    )
}
