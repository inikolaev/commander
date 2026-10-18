import SwiftTreeSitter
import TreeSitterPython

extension SyntaxLanguageDefinition {
    static let python = SyntaxLanguageDefinition(
        id: "python", fileExtensions: ["py", "pyi", "pyw"],
        syntax: { .python }
    )
}

extension TreeSitterSyntaxDefinition {
    static let python = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_python()),
        highlightQuery: """
        (identifier) @variable
        (function_definition name: (identifier) @function)
        (class_definition name: (identifier) @type)
        (call function: (identifier) @function)
        (call function: (attribute attribute: (identifier) @function))
        (attribute attribute: (identifier) @property)
        (type (identifier) @type)
        [(integer) (float)] @number
        [(none) (true) (false)] @constant
        (string) @string
        (interpolation) @variable
        (comment) @comment
        ["as" "assert" "async" "await" "break" "class" "continue" "def"
         "del" "elif" "else" "except" "finally" "for" "from" "global"
         "if" "import" "lambda" "nonlocal" "pass" "raise" "return" "try"
         "while" "with" "yield" "match" "case" "and" "in" "is" "not" "or"] @keyword
        """,
        captures: codeCaptures
    )
}
