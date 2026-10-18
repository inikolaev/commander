import Foundation

public enum SyntaxKind: Sendable, Equatable, Hashable {
    case property
    case string
    case number
    case constant
    case comment
    case keyword
    case function
    case type
    case variable
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
    /// Returns sorted, nonempty, non-overlapping UTF-8 byte spans intersecting the
    /// requested range. Spans use offsets into the original source and may extend
    /// beyond the request; the display projection clips them to visible rows.
    func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan]
}

public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public static let shared = PlainTextSyntaxHighlighter()
    public let isActive = false
    public init() {}
    public func highlights(in byteRange: Range<Int>) -> [SyntaxHighlightSpan] { [] }
}
