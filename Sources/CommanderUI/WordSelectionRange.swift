import Foundation

/// The word boundaries used by the editor and viewer for double-click selection.
enum WordSelectionRange {
    private static let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))

    static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.contains { wordCharacters.contains($0) }
    }

    static func characters(in text: String, at offset: Int) -> Range<Int>? {
        range(in: text, at: offset) { _ in 1 }
    }

    static func utf16(in text: String, at offset: Int) -> Range<Int>? {
        range(in: text, at: offset) { String($0).utf16.count }
    }

    private static func range(
        in text: String, at offset: Int, width: (Character) -> Int
    ) -> Range<Int>? {
        var position = 0
        var wordStart: Int?
        for character in text {
            let end = position + width(character)
            if isWord(character) {
                if wordStart == nil { wordStart = position }
            } else if let start = wordStart {
                if start <= offset && offset <= position { return start..<position }
                wordStart = nil
            }
            if wordStart == nil && offset < end { return nil }
            position = end
        }
        guard let start = wordStart, start <= offset && offset <= position else { return nil }
        return start..<position
    }
}
