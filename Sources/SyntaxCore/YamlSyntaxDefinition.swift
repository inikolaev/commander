import SwiftTreeSitter
import TreeSitterYAML

extension SyntaxLanguageDefinition {
    static let yaml = SyntaxLanguageDefinition(
        id: "yaml", fileExtensions: ["yaml", "yml"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .yaml) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let yaml = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_yaml()),
        highlightQuery: #"""
        [(double_quote_scalar) (single_quote_scalar) (block_scalar) (string_scalar)] @string
        [(integer_scalar) (float_scalar)] @number
        [(boolean_scalar) (null_scalar)] @constant
        (comment) @comment
        (tag) @type
        [(anchor_name) (alias_name)] @variable
        (block_mapping_pair key: (flow_node [(double_quote_scalar) (single_quote_scalar)] @property))
        (block_mapping_pair key: (flow_node (plain_scalar (string_scalar) @property)))
        (flow_mapping (_ key: (flow_node [(double_quote_scalar) (single_quote_scalar)] @property)))
        (flow_mapping (_ key: (flow_node (plain_scalar (string_scalar) @property))))
        """#,
        captures: codeCaptures
    )
}
