import Foundation
import Testing
@testable import SyntaxCore

private func syntaxFixture(_ name: String, contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
}

@Test func jsonRegistryProducesSemanticHighlightSpans() throws {
    let source = #"{"name":"Commander","count":42,"enabled":true,"nothing":null}"#
    let url = try syntaxFixture("sample.json", contents: source)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let highlighter = SyntaxRegistry.viewer.highlighter(for: url)
    let data = Data(source.utf8)
    let spans = highlighter.highlights(in: 0..<data.count)
    let tokens = spans.map { span in
        (span.kind, String(decoding: data[span.byteRange], as: UTF8.self))
    }

    #expect(tokens.contains { $0 == (.property, #""name""#) })
    #expect(tokens.contains { $0 == (.string, #""Commander""#) })
    #expect(tokens.contains { $0 == (.number, "42") })
    #expect(tokens.contains { $0 == (.constant, "true") })
    #expect(tokens.contains { $0 == (.constant, "null") })
}

@Test func unsupportedAndOversizedFilesUsePlainTextHighlighter() throws {
    let textURL = try syntaxFixture("sample.txt", contents: #"{"value":42}"#)
    defer { try? FileManager.default.removeItem(at: textURL.deletingLastPathComponent()) }
    #expect(SyntaxRegistry.viewer.highlighter(for: textURL).highlights(in: 0..<20).isEmpty)

    let jsonURL = try syntaxFixture("sample.json", contents: #"{"value":42}"#)
    defer { try? FileManager.default.removeItem(at: jsonURL.deletingLastPathComponent()) }
    #expect(SyntaxRegistry.viewer.highlighter(for: jsonURL, maximumFileSize: 1)
        .highlights(in: 0..<20).isEmpty)
}
