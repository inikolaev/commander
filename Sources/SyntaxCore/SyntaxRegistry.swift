import Foundation

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

    public func supports(_ url: URL) -> Bool {
        languages.contains { $0.fileExtensions.contains(url.pathExtension.lowercased()) }
    }

    public func highlighter(for url: URL, data: Data,
                            maximumFileSize: Int = Self.defaultMaximumFileSize) -> any SyntaxHighlighter {
        guard data.count <= maximumFileSize,
              let language = languages.first(where: { $0.fileExtensions.contains(url.pathExtension.lowercased()) }) else {
            return PlainTextSyntaxHighlighter.shared
        }
        return (try? language.makeHighlighter(data)) ?? PlainTextSyntaxHighlighter.shared
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
