import SwiftTreeSitter
import TreeSitterHTML

extension SyntaxLanguageDefinition {
    static let html = SyntaxLanguageDefinition(
        id: "html", fileExtensions: ["html", "htm"],
        syntax: { .html }
    )
}

extension TreeSitterSyntaxDefinition {
    static let html = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_html()),
        highlightQuery: #"""
        [(tag_name) (erroneous_end_tag_name)] @type
        (attribute_name) @property
        (attribute_value) @string
        (doctype) @constant
        (comment) @comment
        """#,
        captures: codeCaptures,
        injections: [HTMLLanguageInjections.blocks]
    )
}
