extension TreeSitterSyntaxDefinition {
    /// Shared semantic roles; language queries choose which nodes receive them.
    static let codeCaptures: [String: SyntaxCaptureStyle] = [
        "variable": SyntaxCaptureStyle(kind: .variable),
        "property": SyntaxCaptureStyle(kind: .property, priority: 1),
        "function": SyntaxCaptureStyle(kind: .function, priority: 2),
        "type": SyntaxCaptureStyle(kind: .type, priority: 2),
        "number": SyntaxCaptureStyle(kind: .number),
        "constant": SyntaxCaptureStyle(kind: .constant),
        "string": SyntaxCaptureStyle(kind: .string),
        "comment": SyntaxCaptureStyle(kind: .comment),
        "keyword": SyntaxCaptureStyle(kind: .keyword),
    ]
}
