import Testing
@testable import SyntaxCore

@Test func swiftLanguageHighlights() {
    expectLanguageHighlights("sample.swift", aliases: ["member.SWIFT"], source: #"""
    // greeting
    struct Greeter {
        func greet(name: String) -> String {
            let count = 42
            let ready = true
            return "hé"
        }
    }
    """#, expected: [
        (.comment, "// greeting"),
        (.keyword, "struct"),
        (.type, "Greeter"),
        (.keyword, "func"),
        (.function, "greet"),
        (.type, "String"),
        (.number, "42"),
        (.constant, "true"),
        (.string, "\"hé\""),
    ])
}
