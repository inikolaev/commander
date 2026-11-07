import Foundation

struct FoundationByteMatcher: ByteLiteralMatching {
    let pattern: Data
    let direction: SearchDirection

    func find(in bytes: Data) -> Int? {
        let options: Data.SearchOptions = direction == .backward ? .backwards : []
        return bytes.range(of: pattern, options: options).map { $0.lowerBound - bytes.startIndex }
    }
}
