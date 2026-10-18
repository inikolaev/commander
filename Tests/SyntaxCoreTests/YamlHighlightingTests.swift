import Testing
@testable import SyntaxCore

@Test func yamlLanguageHighlights() {
    expectLanguageHighlights("sample.yaml", aliases: ["member.YAML", "member.YML"], source: #"""
    # config
    name: "hé"
    count: 42
    enabled: true
    inline: {key: false}
    text: |
      first
      second
    """#, expected: [
        (.comment, "# config"),
        (.property, "name"),
        (.string, "\"hé\""),
        (.number, "42"),
        (.constant, "true"),
        (.property, "key"),
        (.constant, "false"),
    ])
}
