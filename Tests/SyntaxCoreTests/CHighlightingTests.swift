import Testing
@testable import SyntaxCore

@Test func cLanguageHighlights() {
    expectLanguageHighlights("sample.c", aliases: ["member.C", "member.H"], source: #"""
    #include <stdio.h>
    bool ready = true;
    // greeting
    int greet(void) { const char *name = "hé"; return 42; }
    """#, expected: [
        (.keyword, "#include"),
        (.string, "<stdio.h>"),
        (.constant, "true"),
        (.comment, "// greeting"),
        (.type, "int"),
        (.function, "greet"),
        (.string, "\"hé\""),
        (.keyword, "return"),
        (.number, "42"),
    ])
}
