import SwiftTreeSitter
import TreeSitterCSS

extension SyntaxLanguageDefinition {
    static let css = SyntaxLanguageDefinition(
        id: "css", fileExtensions: ["css"],
        syntax: { .css }
    )
}

extension TreeSitterSyntaxDefinition {
    static let css = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_css()),
        highlightQuery: #"""
        (comment) @comment
        [(tag_name) (nesting_selector) (universal_selector)] @type
        [(class_name) (id_name) (namespace_name) (property_name) (feature_name) (attribute_name)] @property
        (function_name) @function
        [(string_value) (color_value)] @string
        [(integer_value) (float_value)] @number
        (unit) @type
        ["@media" "@import" "@charset" "@namespace" "@supports" "@keyframes"] @keyword
        [(at_keyword) (to) (from) (important)] @keyword
        """#,
        captures: codeCaptures
    )
}
