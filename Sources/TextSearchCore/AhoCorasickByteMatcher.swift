import Foundation

/// A one-pattern Aho-Corasick trie is one path; these are its failure links.
/// This is the byte KMP automaton, prepared once for the selected direction.
struct AhoCorasickByteMatcher: ByteLiteralMatching {
    let pattern: [UInt8]
    let failure: [Int]
    let direction: SearchDirection

    init(pattern bytes: Data, direction: SearchDirection) {
        self.direction = direction
        let forward = Array(bytes)
        pattern = direction == .backward ? Array(forward.reversed()) : forward
        var links = [Int](repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            for index in 1..<pattern.count {
                var prefix = links[index - 1]
                while prefix > 0 && pattern[prefix] != pattern[index] {
                    prefix = links[prefix - 1]
                }
                if pattern[prefix] == pattern[index] { prefix += 1 }
                links[index] = prefix
            }
        }
        failure = links
    }

    func find(in bytes: Data) -> Int? {
        direction == .forward ? findForward(bytes) : findBackward(bytes)
    }

    private func findForward(_ bytes: Data) -> Int? {
        bytes.withUnsafeBytes { raw in
            var state = 0
            for index in 0..<raw.count {
                let byte = raw[index]
                while state > 0 && pattern[state] != byte { state = failure[state - 1] }
                if pattern[state] == byte { state += 1 }
                if state == pattern.count { return index + 1 - state }
            }
            return nil
        }
    }

    private func findBackward(_ bytes: Data) -> Int? {
        bytes.withUnsafeBytes { raw in
            var state = 0
            var index = raw.count
            while index > 0 {
                index -= 1
                let byte = raw[index]
                while state > 0 && pattern[state] != byte { state = failure[state - 1] }
                if pattern[state] == byte { state += 1 }
                if state == pattern.count { return index }
            }
            return nil
        }
    }
}
