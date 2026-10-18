import Testing
@testable import SyntaxCore

@Test func htmlLanguageHighlights() {
    expectLanguageHighlights("sample.html", aliases: ["member.HTML", "member.HTM"], source: #"""
    <!DOCTYPE html>
    <!-- greeting -->
    <div title="hé">Hello</div>
    <script>const count = 42;</script>
    """#, expected: [
        (.constant, "<!DOCTYPE html>"),
        (.comment, "<!-- greeting -->"),
        (.type, "div"),
        (.property, "title"),
        (.string, "hé"),
        (.type, "script"),
    ])
}
