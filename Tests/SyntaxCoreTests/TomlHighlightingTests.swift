import Testing
@testable import SyntaxCore

@Test func tomlLanguageHighlights() {
    expectLanguageHighlights("sample.toml", aliases: ["member.TOML"], source: #"""
    # config
    [server]
    name = "hé"
    count = 42
    enabled = true
    created = 2026-10-18
    text = """first
    second"""
    """#, expected: [
        (.comment, "# config"),
        (.property, "server"),
        (.property, "name"),
        (.string, "\"hé\""),
        (.number, "42"),
        (.constant, "true"),
        (.string, "2026-10-18"),
        (.string, "\"\"\"first\nsecond\"\"\""),
    ])
}
