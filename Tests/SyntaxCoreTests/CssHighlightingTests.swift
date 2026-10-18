import Testing
@testable import SyntaxCore

@Test func cssLanguageHighlights() {
    expectLanguageHighlights("sample.CSS", source: #"""
    /* hé */
    @media screen {
     .card { color: #fff; width: calc(100% - 2px); content: "hé"; }
    }
    """#, expected: [
        (.comment, "/* hé */"),
        (.keyword, "@media"),
        (.property, "card"),
        (.property, "color"),
        (.string, "#fff"),
        (.function, "calc"),
        (.number, "100"),
        (.type, "%"),
        (.string, "\"hé\""),
    ])
}
