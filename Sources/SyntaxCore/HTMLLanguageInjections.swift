import Foundation
import SwiftTreeSitter

/// HTML-specific language selection is separate from generic layer composition.
enum HTMLLanguageInjections {
    static let blocks = TreeSitterSyntaxInjection(
        query: """
        (script_element (raw_text) @injection.content)
        (style_element (raw_text) @injection.content)
        """,
        language: { content, source in
            guard let element = content.parent,
                  let tag = children(element).first(where: { $0.nodeType == "start_tag" }) else { return nil }
            var attributes: [String: String] = [:]
            for attribute in children(tag) where attribute.nodeType == "attribute" {
                guard let name = children(attribute).first(where: { $0.nodeType == "attribute_name" }) else { continue }
                let key = text(name, source).lowercased()
                // HTML keeps the first occurrence of a duplicate attribute.
                guard attributes[key] == nil else { continue }
                let value = children(attribute).first(where: {
                    $0.nodeType == "attribute_value" || $0.nodeType == "quoted_attribute_value"
                })
                let unquoted = value.flatMap { node in
                    node.nodeType == "quoted_attribute_value"
                        ? children(node).first(where: { $0.nodeType == "attribute_value" }) : node
                }
                attributes[key] = unquoted.map { text($0, source) } ?? ""
            }
            let type = attributes["type"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let mime = type.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if element.nodeType == "style_element" {
                return type.isEmpty || mime == "text/css" ? .css : nil
            }
            guard attributes["src"] == nil else { return nil }
            if ["application/json", "application/ld+json"].contains(mime)
                || ["importmap", "speculationrules"].contains(type) { return .json }
            if type == "module" { return .javascript }
            if type.isEmpty {
                if attributes["type"] == nil, let legacy = attributes["language"], !legacy.isEmpty {
                    return javascriptMIMETypes.contains("text/" + legacy.lowercased()) ? .javascript : nil
                }
                return .javascript
            }
            return javascriptMIMETypes.contains(mime) ? .javascript : nil
        }
    )

    private static let javascriptMIMETypes: Set<String> = [
        "application/ecmascript", "application/javascript", "application/x-ecmascript",
        "application/x-javascript", "text/ecmascript", "text/javascript",
        "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
        "text/javascript1.3", "text/javascript1.4", "text/javascript1.5",
        "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript"
    ]

    private static func children(_ node: Node) -> [Node] {
        (0..<node.namedChildCount).compactMap { node.namedChild(at: $0) }
    }

    private static func text(_ node: Node, _ source: Data) -> String {
        let bytes = node.byteRange
        return String(decoding: source[Int(bytes.lowerBound)..<Int(bytes.upperBound)], as: UTF8.self)
    }
}
