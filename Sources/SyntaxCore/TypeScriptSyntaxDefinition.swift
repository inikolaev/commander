import SwiftTreeSitter
import TreeSitterTypeScript
import TreeSitterTSX

extension SyntaxLanguageDefinition {
    static let typescript = SyntaxLanguageDefinition(
        id: "typescript", fileExtensions: ["ts", "mts", "cts"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .typescript) }
    )
    static let tsx = SyntaxLanguageDefinition(
        id: "tsx", fileExtensions: ["tsx"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .tsx) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let typescript = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_typescript()),
        highlightQuery: javascriptQuery + "\n" + typescriptQuery,
        captures: codeCaptures
    )
    static let tsx = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_tsx()),
        highlightQuery: javascriptQuery + "\n" + typescriptQuery + "\n" + jsxQuery,
        captures: codeCaptures
    )

    private static let typescriptQuery = """
    (type_identifier) @type
    (predefined_type) @type
    ["abstract" "declare" "enum" "implements" "interface" "keyof" "namespace"
     "private" "protected" "public" "type" "readonly" "override" "satisfies"] @keyword
    """
}
