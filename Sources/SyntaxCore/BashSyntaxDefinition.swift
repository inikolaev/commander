import SwiftTreeSitter
import TreeSitterBash

extension SyntaxLanguageDefinition {
    static let bash = SyntaxLanguageDefinition(
        id: "bash", fileExtensions: ["sh", "bash"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .bash) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let bash = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_bash()),
        highlightQuery: """
        [(string) (raw_string) (heredoc_body) (heredoc_start)] @string
        (command_name) @function
        (function_definition name: (word) @function)
        (variable_name) @variable
        [(command_substitution) (process_substitution) (expansion) (simple_expansion)] @variable
        [(number) (file_descriptor)] @number
        (comment) @comment
        ["case" "do" "done" "elif" "else" "esac" "export" "fi" "for"
         "function" "if" "in" "select" "then" "unset" "until" "while"] @keyword
        """,
        captures: codeCaptures
    )
}
