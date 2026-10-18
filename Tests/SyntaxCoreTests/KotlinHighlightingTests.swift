import Testing
@testable import SyntaxCore

@Test func kotlinLanguageHighlights() {
    expectLanguageHighlights("sample.kt", aliases: ["member.KT", "member.KTS"], source: #"""
    // greeting
    class Greeter {
        fun greet(name: String): String {
            val count = 42
            val ready = true
            return "hé $name"
        }
    }
    """#, expected: [
        (.comment, "// greeting"),
        (.keyword, "class"),
        (.type, "Greeter"),
        (.keyword, "fun"),
        (.function, "greet"),
        (.type, "String"),
        (.keyword, "val"),
        (.number, "42"),
        (.constant, "true"),
        (.variable, "name"),
    ])
}
