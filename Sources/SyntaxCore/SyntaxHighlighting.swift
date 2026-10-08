import Foundation
import SwiftTreeSitter
import TreeSitter
import TreeSitterJSON

public enum SyntaxKind: Sendable, Equatable, Hashable {
    case property
    case string
    case number
    case constant
    case comment
}

public struct SyntaxHighlightSpan: Sendable, Equatable {
    public let byteRange: Range<Int>
    public let kind: SyntaxKind

    public init(byteRange: Range<Int>, kind: SyntaxKind) {
        self.byteRange = byteRange
        self.kind = kind
    }
}

public protocol SyntaxHighlighter: Sendable {
    var isActive: Bool { get }
    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan]
}

public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public static let shared = PlainTextSyntaxHighlighter()
    public let isActive = false
    public init() {}
    public func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] { [] }
}

public struct SyntaxLanguageDefinition: Sendable {
    public let id: String
    public let fileExtensions: Set<String>
    fileprivate let makeHighlighter: @Sendable (Data) throws -> any SyntaxHighlighter

    public init(
        id: String,
        fileExtensions: Set<String>,
        makeHighlighter: @escaping @Sendable (Data) throws -> any SyntaxHighlighter
    ) {
        self.id = id
        self.fileExtensions = fileExtensions
        self.makeHighlighter = makeHighlighter
    }
}

public struct SyntaxRegistry: Sendable {
    public static let viewer = SyntaxRegistry(languages: [.json])
    public static let defaultMaximumFileSize = 8 * 1024 * 1024

    private let languages: [SyntaxLanguageDefinition]

    public init(languages: [SyntaxLanguageDefinition]) {
        self.languages = languages
    }

    public func highlighter(
        for url: URL,
        maximumFileSize: Int = Self.defaultMaximumFileSize
    ) -> any SyntaxHighlighter {
        let ext = url.pathExtension.lowercased()
        guard let language = languages.first(where: { $0.fileExtensions.contains(ext) }) else {
            return PlainTextSyntaxHighlighter.shared
        }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize,
                  fileSize <= maximumFileSize else {
                return PlainTextSyntaxHighlighter.shared
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= maximumFileSize else {
                return PlainTextSyntaxHighlighter.shared
            }
            return try language.makeHighlighter(data)
        } catch {
            // Syntax highlighting is optional. File viewing must never fail because
            // language detection, parsing, or query setup failed.
            return PlainTextSyntaxHighlighter.shared
        }
    }
}

private extension SyntaxLanguageDefinition {
    static let json = SyntaxLanguageDefinition(
        id: "json",
        fileExtensions: ["json"],
        makeHighlighter: { try TreeSitterJSONHighlighter(source: $0) }
    )
}

private struct TreeSitterJSONHighlighter: SyntaxHighlighter {
    let isActive = true
    private let spans: [SyntaxHighlightSpan]

    init(source: Data) throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_json())
        try parser.setLanguage(language)

        let chunkSize = 64 * 1024
        let oldTree: Tree? = nil
        guard let tree = parser.parse(tree: oldTree, encoding: TSInputEncodingUTF8, readBlock: { offset, _ in
            guard offset < source.count else { return nil }
            let end = min(source.count, offset + chunkSize)
            return source.subdata(in: offset..<end)
        }) else {
            throw SyntaxHighlightingError.parseFailed
        }

        let query = try Query(language: language, data: Data(Self.highlightQuery.utf8))
        let cursor = query.execute(in: tree)
        var captures: [SyntaxHighlightSpan] = []
        while let capture = cursor.nextCapture() {
            guard let name = capture.name,
                  let kind = Self.kind(for: name) else { continue }
            let range = capture.node.byteRange
            captures.append(SyntaxHighlightSpan(
                byteRange: Int(range.lowerBound)..<Int(range.upperBound),
                kind: kind
            ))
        }
        spans = Self.removeExactOverlaps(captures)
    }

    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] {
        guard !spans.isEmpty, !byteRange.isEmpty else { return [] }

        var low = 0
        var high = spans.count
        while low < high {
            let middle = (low + high) / 2
            if spans[middle].byteRange.upperBound <= byteRange.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }

        var result: [SyntaxHighlightSpan] = []
        var index = low
        while index < spans.count, spans[index].byteRange.lowerBound < byteRange.upperBound {
            result.append(spans[index])
            index += 1
        }
        return result
    }

    private static let highlightQuery = """
    (pair key: (string) @property)
    (string) @string
    (number) @number
    [
      (null)
      (true)
      (false)
    ] @constant
    (comment) @comment
    """

    private static func kind(for capture: String) -> SyntaxKind? {
        switch capture {
        case "property": .property
        case "string": .string
        case "number": .number
        case "constant": .constant
        case "comment": .comment
        default: nil
        }
    }

    private static func removeExactOverlaps(_ input: [SyntaxHighlightSpan]) -> [SyntaxHighlightSpan] {
        let priority: [SyntaxKind: Int] = [
            .property: 2,
            .string: 1,
            .number: 1,
            .constant: 1,
            .comment: 1,
        ]
        let sorted = input.sorted {
            if $0.byteRange.lowerBound != $1.byteRange.lowerBound {
                return $0.byteRange.lowerBound < $1.byteRange.lowerBound
            }
            if $0.byteRange.upperBound != $1.byteRange.upperBound {
                return $0.byteRange.upperBound < $1.byteRange.upperBound
            }
            return priority[$0.kind, default: 0] > priority[$1.kind, default: 0]
        }

        var result: [SyntaxHighlightSpan] = []
        for span in sorted {
            if let last = result.last, last.byteRange == span.byteRange {
                continue
            }
            result.append(span)
        }
        return result
    }
}

private enum SyntaxHighlightingError: Error {
    case parseFailed
}
