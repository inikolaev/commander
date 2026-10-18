import SwiftTreeSitter
import TreeSitterJSON

extension SyntaxLanguageDefinition {
    static let json = SyntaxLanguageDefinition(
        id: "json",
        fileExtensions: ["json"],
        syntax: { .json }
    )
}

extension TreeSitterSyntaxDefinition {
    static let json = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_json()),
        highlightQuery: """
        (pair key: (string) @property)
        (string) @string
        (number) @number
        [(null) (true) (false)] @constant
        (comment) @comment
        """,
        captures: [
            "property": SyntaxCaptureStyle(kind: .property, priority: 1),
            "string": SyntaxCaptureStyle(kind: .string),
            "number": SyntaxCaptureStyle(kind: .number),
            "constant": SyntaxCaptureStyle(kind: .constant),
            "comment": SyntaxCaptureStyle(kind: .comment),
        ]
    )
}
