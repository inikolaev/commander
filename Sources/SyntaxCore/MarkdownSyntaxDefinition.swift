import SwiftTreeSitter
import TreeSitterMarkdown
import TreeSitterMarkdownInline

extension SyntaxLanguageDefinition {
    static let markdown = SyntaxLanguageDefinition(
        id: "markdown", fileExtensions: ["md", "markdown", "mdown", "mkd", "mkdn"],
        makeHighlighter: { try TreeSitterSyntaxHighlighter(source: $0, definition: .markdown) }
    )
}

extension TreeSitterSyntaxDefinition {
    static let markdown = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_markdown()),
        highlightQuery: """
        (atx_heading (inline) @keyword)
        (setext_heading (paragraph (inline) @keyword))
        [(atx_h1_marker) (atx_h2_marker) (atx_h3_marker) (atx_h4_marker)
         (atx_h5_marker) (atx_h6_marker) (setext_h1_underline) (setext_h2_underline)] @keyword
        [(list_marker_plus) (list_marker_minus) (list_marker_star)
         (list_marker_dot) (list_marker_parenthesis) (thematic_break)
         (block_quote_marker) (block_continuation) (fenced_code_block_delimiter)] @keyword
        [(task_list_marker_checked) (task_list_marker_unchecked)] @constant
        [(fenced_code_block) (indented_code_block)] @string
        (info_string) @type
        (pipe_table_header (pipe_table_cell) @keyword)
        (pipe_table_delimiter_row) @keyword
        (link_destination) @string
        (link_label) @function
        (link_title) @string
        [(minus_metadata) (plus_metadata)] @comment
        """,
        captures: codeCaptures,
        injections: [
            TreeSitterSyntaxInjection(query: "[(inline) (pipe_table_cell)] @injection.content",
                                     language: { _, _ in .markdownInline },
                                     excludingChildTypes: ["block_continuation"]),
            TreeSitterSyntaxInjection(query: "(fenced_code_block (code_fence_content) @injection.content)",
                                     language: MarkdownCodeFences.language,
                                     excludingChildTypes: ["block_continuation"], defaultKind: .variable),
            TreeSitterSyntaxInjection(query: "(html_block) @injection.content",
                                     language: { _, _ in .html },
                                     excludingChildTypes: ["block_continuation"])
        ]
    )

    static let markdownInline = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_markdown_inline()),
        highlightQuery: """
        (emphasis) @property
        (strong_emphasis) @constant
        (strikethrough) @comment
        [(code_span) (link_title) (link_destination) (uri_autolink) (email_autolink)] @string
        [(link_text) (link_label) (image_description)] @function
        [(backslash_escape) (entity_reference) (numeric_character_reference)] @constant
        """,
        captures: [
            "property": SyntaxCaptureStyle(kind: .property),
            "constant": SyntaxCaptureStyle(kind: .constant),
            "comment": SyntaxCaptureStyle(kind: .comment),
            "string": SyntaxCaptureStyle(kind: .string, priority: 2),
            "function": SyntaxCaptureStyle(kind: .function)
        ],
        injections: [TreeSitterSyntaxInjection(query: "(html_tag) @injection.content", language: { _, _ in .html })]
    )
}
