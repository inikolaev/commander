import Testing
@testable import SyntaxCore

@Test func rustLanguageHighlights() {
    expectLanguageHighlights("sample.rs", aliases: ["member.RS"], source: #"""
    // greeting
    pub fn greet(name: &str) -> i32 {
        let count = 42;
        let ready = true;
        println!("hé");
        return count;
    }
    """#, expected: [
        (.comment, "// greeting"),
        (.keyword, "pub"),
        (.keyword, "fn"),
        (.function, "greet"),
        (.type, "str"),
        (.type, "i32"),
        (.number, "42"),
        (.constant, "true"),
        (.function, "println"),
        (.string, "\"hé\""),
    ])
}
