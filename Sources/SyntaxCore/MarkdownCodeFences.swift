import Foundation
import SwiftTreeSitter

/// Extracts only the fence label; the shared registry owns language resolution.
enum MarkdownCodeFences {
    static func languageAlias(_ content: Node, _ source: Data) -> String? {
        guard let block = content.parent,
              let info = (0..<block.namedChildCount).compactMap({ block.namedChild(at: $0) })
                .first(where: { $0.nodeType == "info_string" }),
              let name = (0..<info.namedChildCount).compactMap({ info.namedChild(at: $0) })
                .first(where: { $0.nodeType == "language" }) else { return nil }
        let bytes = name.byteRange
        let label = String(decoding: source[Int(bytes.lowerBound)..<Int(bytes.upperBound)], as: UTF8.self).lowercased()
        return label
    }
}
