import Foundation

/// A prepared matcher for a nonempty needle and a bound search direction.
/// Each call returns the first match in that direction, relative to the supplied
/// Data slice. Partial-match state starts fresh per call; adaptive state may persist.
/// The scanner handles folding, Unicode fallback, chunk boundaries, and coordinates.
protocol ByteLiteralMatching: Sendable {
    mutating func find(in bytes: Data) -> Int?
}

/// Benchmark selector. The public scanner initializer always chooses Foundation.
@_spi(Benchmark)
public enum ASCIILiteralMatcher: Sendable {
    case foundation
    case darwinMemmem
    case simdShort
    case ahoCorasick

    func prepare(pattern: Data, direction: SearchDirection) -> any ByteLiteralMatching {
        switch self {
        case .foundation: FoundationByteMatcher(pattern: pattern, direction: direction)
        case .darwinMemmem: DarwinMemmemByteMatcher(pattern: pattern, direction: direction)
        case .simdShort: SIMDShortByteMatcher(pattern: pattern, direction: direction)
        case .ahoCorasick: AhoCorasickByteMatcher(pattern: pattern, direction: direction)
        }
    }
}
