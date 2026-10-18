import Testing
@testable import SyntaxCore

@Test func javaLanguageHighlights() {
    expectLanguageHighlights("sample.java", aliases: ["member.JAVA"], source: #"""
    // greeting
    public class Greeter {
        public String greet() { int count = 42; boolean ready = true; return "hé"; }
    }
    """#, expected: [
        (.comment, "// greeting"),
        (.keyword, "public"),
        (.keyword, "class"),
        (.type, "Greeter"),
        (.type, "String"),
        (.function, "greet"),
        (.type, "int"),
        (.number, "42"),
        (.constant, "true"),
        (.string, "\"hé\""),
    ])
}
