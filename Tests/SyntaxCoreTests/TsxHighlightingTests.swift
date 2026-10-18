import Testing
@testable import SyntaxCore

@Test func tsxLanguageHighlights() {
    expectLanguageHighlights("sample.tsx", aliases: ["member.TSX"], source: #"""
    type Props = { name: string };
    const Greeting = (props: Props) => <span title="hello">{props.name}</span>;
    """#, expected: [
        (.keyword, "type"),
        (.type, "Props"),
        (.type, "string"),
        (.function, "Greeting"),
        (.string, "\"hello\""),
        (.property, "name"),
        (.type, "span"),
    ])
}
