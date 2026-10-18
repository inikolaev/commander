import Testing
@testable import SyntaxCore

@Test func goLanguageHighlights() {
    expectLanguageHighlights("sample.go", aliases: ["member.GO"], source: #"""
    package main
    // greeting
    func greet(name string) string { return "hé" }
    var count = 42
    var enabled = true
    """#, expected: [
        (.keyword, "package"),
        (.comment, "// greeting"),
        (.keyword, "func"),
        (.function, "greet"),
        (.type, "string"),
        (.string, "\"hé\""),
        (.number, "42"),
        (.constant, "true"),
    ])
}
