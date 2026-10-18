import Testing
@testable import SyntaxCore

@Test func cppLanguageHighlights() {
    expectLanguageHighlights("sample.CPP", aliases: ["member.CC", "member.CPP", "member.CXX", "member.C++", "member.HH", "member.HPP", "member.HXX", "member.H++", "member.IPP", "member.TPP"], source: #"""
    bool ready = true;
    // greeting
    class Greeter { public: int greet() { return 42; } };
    const char *value = R"(hé
    world)";
    """#, expected: [
        (.constant, "true"),
        (.comment, "// greeting"),
        (.keyword, "class"),
        (.type, "Greeter"),
        (.keyword, "public"),
        (.function, "greet"),
        (.number, "42"),
        (.string, "R\"(hé\nworld)\""),
    ])
}
