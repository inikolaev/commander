import Foundation

public struct SyntaxLanguageDefinition: Sendable {
    public let id: String
    public let fileExtensions: Set<String>
    public let fileNames: Set<String>
    public let aliases: Set<String>
    fileprivate let makeSyntaxDefinition: (@Sendable () -> TreeSitterSyntaxDefinition)?
    fileprivate let makeHighlighter: @Sendable (Data, SyntaxRegistry) throws -> any SyntaxHighlighter

    public init(
        id: String,
        fileExtensions: Set<String>,
        fileNames: Set<String> = [],
        makeHighlighter: @escaping @Sendable (Data) throws -> any SyntaxHighlighter
    ) {
        self.id = id
        self.fileExtensions = fileExtensions
        self.fileNames = fileNames
        self.aliases = []
        self.makeSyntaxDefinition = nil
        self.makeHighlighter = { source, _ in try makeHighlighter(source) }
    }

    /// A single lazy grammar factory serves standalone files and named injections.
    /// IDs/extensions are aliases automatically; only additional names need listing.
    init(id: String, fileExtensions: Set<String>, fileNames: Set<String> = [],
         aliases: Set<String> = [], syntax: @escaping @Sendable () -> TreeSitterSyntaxDefinition) {
        self.id = id
        self.fileExtensions = fileExtensions
        self.fileNames = fileNames
        self.aliases = Set(aliases.union(fileExtensions).union([id]).map { $0.lowercased() })
        self.makeSyntaxDefinition = syntax
        self.makeHighlighter = { source, registry in
            try TreeSitterSyntaxHighlighter(source: source, definition: syntax(), registry: registry)
        }
    }

    fileprivate func matches(_ url: URL) -> Bool {
        fileNames.contains(url.lastPathComponent) || fileExtensions.contains(url.pathExtension.lowercased())
    }
}

public struct SyntaxRegistry: Sendable {
    public static let viewer = SyntaxRegistry(languages: [.json, .python, .ruby, .c, .cpp, .go, .bash, .javascript, .html, .typescript, .tsx, .yaml, .toml, .java, .kotlin, .swift, .rust, .starlark, .css, .markdown])
    public static let defaultMaximumFileSize = 8 * 1024 * 1024

    private let languages: [SyntaxLanguageDefinition]

    public init(languages: [SyntaxLanguageDefinition]) {
        self.languages = languages
    }

    func syntaxDefinition(forAlias alias: String) -> TreeSitterSyntaxDefinition? {
        languages.first { $0.aliases.contains(alias.lowercased()) }?.makeSyntaxDefinition?()
    }

    public func supports(_ url: URL) -> Bool {
        languages.contains { $0.matches(url) }
    }

    /// Creates a serialized editing session for already-normalized UTF-8 content.
    /// Unsupported formats and oversized content yield plain-text snapshots.
    public func editingSession(for url: URL, data: Data,
                               maximumFileSize: Int = Self.defaultMaximumFileSize) -> SyntaxEditingSession {
        let language = languages.first(where: { $0.matches(url) })
        let definition = language?.makeSyntaxDefinition?()
        return SyntaxEditingSession(source: data, definition: definition, registry: self,
                                    maximumFileSize: maximumFileSize,
                                    fallbackHighlighter: definition == nil ? language?.makeHighlighter : nil)
    }

    public func highlighter(for url: URL, data: Data,
                            maximumFileSize: Int = Self.defaultMaximumFileSize) -> any SyntaxHighlighter {
        guard data.count <= maximumFileSize,
              let language = languages.first(where: { $0.matches(url) }) else {
            return PlainTextSyntaxHighlighter.shared
        }
        return (try? language.makeHighlighter(data, self)) ?? PlainTextSyntaxHighlighter.shared
    }

    public func highlighter(
        for url: URL,
        maximumFileSize: Int = Self.defaultMaximumFileSize
    ) -> any SyntaxHighlighter {
        guard let language = languages.first(where: { $0.matches(url) }) else {
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
            return try language.makeHighlighter(data, self)
        } catch {
            // Syntax highlighting is optional. File viewing must never fail because
            // language detection, parsing, or query setup failed.
            return PlainTextSyntaxHighlighter.shared
        }
    }
}
