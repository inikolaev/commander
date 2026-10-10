import Foundation
import Testing
import EditorCore

private func fixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

@Test func savePreservesSymlinkBOMLineEndingsAndPermissions() throws {
    try fixture { root in
        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try Data([0xEF, 0xBB, 0xBF] + Array("first\r\nsecond".utf8)).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target")
        let file = try EditorFile.open(link)
        #expect(file.text == "first\nsecond")
        let saved = try file.save(text: "first\nnew\nsecond")
        #expect(saved.text == "first\nnew\nsecond")
        #expect(try Data(contentsOf: target) == Data([0xEF, 0xBB, 0xBF] + Array("first\r\nnew\r\nsecond".utf8)))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target")
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int == 0o640)
    }
}

@Test func externalChangesAndUnsupportedFilesAreRejected() throws {
    try fixture { root in
        let target = root.appendingPathComponent("file")
        try Data("before".utf8).write(to: target)
        let file = try EditorFile.open(target)
        try Data("external".utf8).write(to: target)
        #expect(throws: EditorFile.Failure.self) { try file.save(text: "ours") }
        #expect(try String(contentsOf: target, encoding: .utf8) == "external")
        for data in [Data([0xFF]), Data([0]), Data("a\r\nb\n".utf8)] {
            try data.write(to: target)
            #expect(throws: EditorFile.Failure.self) { try EditorFile.open(target) }
        }
        #expect(throws: EditorFile.Failure.self) { try EditorFile.open(root) }
    }
}

@Test func hardLinksAreNotSilentlyBrokenOnSave() throws {
    try fixture { root in
        let target = root.appendingPathComponent("original")
        try Data("before".utf8).write(to: target)
        try FileManager.default.linkItem(at: target, to: root.appendingPathComponent("linked"))
        let file = try EditorFile.open(target)
        #expect(throws: EditorFile.Failure.self) { try file.save(text: "after") }
    }
}


@Test func editorOpensAndSavesBeyondFormerSizeLimit() throws {
    try fixture { root in
        let target = root.appendingPathComponent("large.txt")
        let text = String(repeating: "A line of test text.\n", count: 900_000)
        #expect(text.utf8.count > 16 * 1024 * 1024)
        try Data(text.utf8).write(to: target)
        let file = try EditorFile.open(target)
        #expect(file.text == text)
        let edited = text + "Added at the end.\n"
        let saved = try file.save(text: edited)
        #expect(saved.text == edited)
        #expect(try String(contentsOf: target, encoding: .utf8) == edited)
        // Growth and truncation both count as conflicts with the saved snapshot.
        try Data((edited + "external").utf8).write(to: target)
        #expect(throws: EditorFile.Failure.self) { try saved.save(text: text) }
        try Data("short".utf8).write(to: target)
        #expect(throws: EditorFile.Failure.self) { try saved.save(text: text) }
    }
}

@Test func newlinePreparationPreservesUnicodeAndRoundTripsEveryStyle() throws {
    try fixture { root in
        let target = root.appendingPathComponent("newlines.txt")
        for newline in ["\n", "\r\n", "\r"] {
            for bom in [false, true] {
                for lines in [[""], ["no final newline"], ["", ""],
                              ["Märkätilan 👩‍💻", "", "e\u{301} 漢字", ""]] {
                    let raw = lines.joined(separator: newline)
                    let bytes = Data((bom ? [0xEF, 0xBB, 0xBF] : []) + Array(raw.utf8))
                    try bytes.write(to: target)
                    let file = try EditorFile.open(target)
                    let document = EditorDocuments.make(file: file)
                    let expected = lines.joined(separator: "\n")
                    #expect(file.text == expected)
                    #expect(document.text(in: NSRange(location: 0, length: document.length)) == expected)
                    _ = try file.save(text: expected)
                    #expect(try Data(contentsOf: target) == bytes)
                }
            }
        }
        for bytes in [Data("a\r\nb\r".utf8), Data("a\rb\n".utf8),
                      Data("a\r\nb\n".utf8), Data([13, 10, 0]),
                      Data([13, 0xFF]), Data([0xC3, 13, 10, 0xA9])] {
            try bytes.write(to: target)
            #expect(throws: EditorFile.Failure.self) { try EditorFile.open(target) }
        }
    }
}

@Test func pastedMixedNewlinesNormalizeWithoutChangingUnicode() {
    let input = "é\r\n👩‍💻\r漢字\ne\u{301}\r"
    let expected = "é\n👩‍💻\n漢字\ne\u{301}\n"
    let document = EditorDocuments.make(text: input)
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == expected)
    document.replace(NSRange(location: document.length, length: 0), with: input)
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == expected + expected)
    document.undo()
    #expect(document.text(in: NSRange(location: 0, length: document.length)) == expected)
}

@Test func preparedLineIndexMatchesUTF16AcrossByteBlockBoundaries() throws {
    try fixture { root in
        let target = root.appendingPathComponent("indexed.txt")
        for padding in 0..<16 {
            for newline in ["\n", "\r", "\r\n"] {
                let lines = [String(repeating: "a", count: padding),
                    "é漢👩‍💻e\u{301}", "", String(repeating: "b", count: 65),
                    "😀", ""]
                try Data(lines.joined(separator: newline).utf8).write(to: target)
                let file = try EditorFile.open(target)
                let document = EditorDocuments.make(file: file)
                #expect(document.lineCount == lines.count)
                var offset = 0
                for (index, line) in lines.enumerated() {
                    let range = document.lineRange(index)
                    #expect(range == NSRange(location: offset, length: line.utf16.count))
                    #expect(document.text(in: range) == line)
                    #expect(document.lineIndex(at: offset) == index)
                    offset += line.utf16.count + 1
                }
                document.replace(document.lineRange(1), with: "new\n👩‍💻")
                #expect(document.lineCount == lines.count + 1)
                #expect(document.text(in: document.lineRange(2)) == "👩‍💻")
                document.undo()
                #expect(document.text(in: NSRange(location: 0, length: document.length)) == lines.joined(separator: "\n"))
            }
            // NUL and malformed UTF-8 must not escape the ASCII block fast path.
            for invalid: [UInt8] in [[0], [0xC0, 0xAF], [0xF0, 0x80, 0x80, 0x80], [0x80]] {
                let bytes = Array(repeating: UInt8(65), count: padding) + invalid + Array(repeating: UInt8(66), count: 17)
                try Data(bytes).write(to: target)
                #expect(throws: EditorFile.Failure.self) { try EditorFile.open(target) }
            }
        }
    }
}

@Test func newEditorFileIsDeferredAndCannotOverwriteConcurrentCreation() throws {
    try fixture { root in
        let url = root.appendingPathComponent("new.txt")
        let file = try EditorFile.openOrNew(name: "new.txt", in: root)
        #expect(file.isNew)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let saved = try file.save(text: "")
        #expect(!saved.isNew)
        #expect(try Data(contentsOf: url).isEmpty)
        let reopened = try EditorFile.openOrNew(name: "new.txt", in: root)
        #expect(!reopened.isNew)
        #expect(throws: (any Error).self) { try file.save(text: "overwrite") }
        #expect(try Data(contentsOf: url).isEmpty)
        for name in ["", " ", ".", "..", "a/b", "a\0b"] {
            #expect(throws: EditorFile.Failure.self) { try EditorFile.openOrNew(name: name, in: root) }
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing")
        #expect(throws: (any Error).self) { try EditorFile.openOrNew(name: "link", in: root) }
    }
}
