import SwiftTreeSitter
import TreeSitterTOML

extension SyntaxLanguageDefinition {
    static let toml = SyntaxLanguageDefinition(
        id: "toml", fileExtensions: ["toml"],
        syntax: { .toml }
    )
}

extension TreeSitterSyntaxDefinition {
    static let toml = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_toml()),
        highlightQuery: #"""
        [(bare_key) (quoted_key)] @property
        (string) @string
        [(integer) (float)] @number
        (boolean) @constant
        [(offset_date_time) (local_date_time) (local_date) (local_time)] @string
        (comment) @comment
        """#,
        captures: codeCaptures
    )
}
