import Testing
@testable import SyntaxCore

@Test func starlarkLanguageHighlights() {
    expectLanguageHighlights("BUILD", aliases: ["member.BZL", "member.BAZEL", "WORKSPACE", "BUILD.bazel", "WORKSPACE.bazel", "MODULE.bazel"], source: #"""
    # build rule
    load("//tools:rules.bzl", "my_rule")
    my_rule(name = "hé", count = 42, enabled = True)
    def helper(value):
        return value
    """#, expected: [
        (.comment, "# build rule"),
        (.function, "load"),
        (.string, "\"//tools:rules.bzl\""),
        (.function, "my_rule"),
        (.property, "name"),
        (.string, "\"hé\""),
        (.number, "42"),
        (.constant, "True"),
        (.keyword, "def"),
        (.function, "helper"),
        (.keyword, "return"),
    ])
}
