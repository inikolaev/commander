import Foundation
import SwiftTreeSitter

/// Fence aliases are explicit: unknown or unlabelled fences retain code styling.
enum MarkdownCodeFences {
    static func language(_ content: Node, _ source: Data) -> TreeSitterSyntaxDefinition? {
        guard let block = content.parent,
              let info = (0..<block.namedChildCount).compactMap({ block.namedChild(at: $0) })
                .first(where: { $0.nodeType == "info_string" }),
              let name = (0..<info.namedChildCount).compactMap({ info.namedChild(at: $0) })
                .first(where: { $0.nodeType == "language" }) else { return nil }
        let bytes = name.byteRange
        let label = String(decoding: source[Int(bytes.lowerBound)..<Int(bytes.upperBound)], as: UTF8.self).lowercased()
        return definitions[label]?()
    }

    // Factories avoid eagerly constructing recursive Markdown definitions.
    private static let definitions: [String: @Sendable () -> TreeSitterSyntaxDefinition] = [
        "json": { .json },
        "python": { .python }, "py": { .python },
        "c": { .c }, "cpp": { .cpp }, "c++": { .cpp },
        "go": { .go }, "golang": { .go },
        "bash": { .bash }, "sh": { .bash }, "shell": { .bash },
        "html": { .html },
        "javascript": { .javascript }, "js": { .javascript }, "jsx": { .javascript },
        "typescript": { .typescript }, "ts": { .typescript }, "tsx": { .tsx },
        "yaml": { .yaml }, "yml": { .yaml }, "toml": { .toml },
        "java": { .java }, "kotlin": { .kotlin }, "kt": { .kotlin }, "kts": { .kotlin },
        "swift": { .swift }, "rust": { .rust }, "rs": { .rust },
        "starlark": { .starlark }, "bazel": { .starlark }, "bzl": { .starlark },
        "css": { .css }, "markdown": { .markdown }, "md": { .markdown }
    ]
}
