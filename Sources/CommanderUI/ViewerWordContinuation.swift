import Foundation
import FileManagerCore

struct ViewerWordContinuationRequest: Sendable {
    let token: UInt64
    let before: Int64?
    let beforeContext: String
    let after: Int64?
    let afterContext: String
    let revision: UInt64?
    let fileSize: Int64?
}

struct ViewerWordContinuation: Sendable {
    let prefix: String
    let suffix: String

    static func load(
        from source: any FileContentSource,
        request: ViewerWordContinuationRequest
    ) async throws -> Self {
        try await verifySource(source, request: request)
        let prefix: String
        if let before = request.before {
            let withContext = try await precedingWord(from: source, endingAt: before,
                context: request.beforeContext)
            prefix = String(decoding: withContext.utf8.dropLast(request.beforeContext.utf8.count),
                as: UTF8.self)
        } else {
            prefix = ""
        }
        let suffix: String
        if let after = request.after {
            let context = (prefix.last.map(String.init) ?? "") + request.afterContext
            let withContext = try await followingWord(from: source, startingAt: after,
                context: context)
            suffix = String(decoding: withContext.utf8.dropFirst(context.utf8.count),
                as: UTF8.self)
        } else {
            suffix = ""
        }
        try await verifySource(source, request: request)
        return Self(prefix: prefix, suffix: suffix)
    }

    private static func verifySource(
        _ source: any FileContentSource, request: ViewerWordContinuationRequest
    ) async throws {
        let metadata = try await source.metadata()
        guard metadata.revision == request.revision,
            request.fileSize == nil || metadata.size == nil || metadata.size == request.fileSize else {
            throw FileViewerError.sourceChanged
        }
    }

    private static func completeUTF8PrefixLength(_ bytes: Data) -> Int {
        guard !bytes.isEmpty else { return 0 }
        let array = Array(bytes.suffix(4))
        var lead = array.count - 1
        while lead > 0 && array[lead] & 0xC0 == 0x80 { lead -= 1 }
        let first = array[lead]
        let expected: Int
        switch first {
        case 0xC2...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF4: expected = 4
        default: expected = 1
        }
        return bytes.count - (array.count - lead < expected ? array.count - lead : 0)
    }

    private static func followingWord(
        from source: any FileContentSource, startingAt offset: Int64, context: String
    ) async throws -> String {
        var cursor = offset
        var pendingBytes = Data()
        var pendingCharacter = context
        var pieces: [String] = []
        while true {
            try Task.checkCancellation()
            let chunk = try await source.read(at: cursor, count: 4096)
            cursor += Int64(chunk.count)
            pendingBytes.append(chunk)
            let atEnd = chunk.count < 4096
            let decodedCount = atEnd ? pendingBytes.count : completeUTF8PrefixLength(pendingBytes)
            let decoded = String(decoding: pendingBytes.prefix(decodedCount), as: UTF8.self)
            pendingBytes.removeFirst(decodedCount)
            let combined = pendingCharacter + decoded
            guard !combined.isEmpty else { continue }
            let trustedEnd = atEnd ? combined.endIndex : combined.index(before: combined.endIndex)
            if let stop = combined[..<trustedEnd].firstIndex(where: { !WordSelectionRange.isWord($0) }) {
                pieces.append(String(combined[..<stop]))
                return pieces.joined()
            }
            pieces.append(String(combined[..<trustedEnd]))
            if atEnd { return pieces.joined() }
            pendingCharacter = String(combined[trustedEnd...])
        }
    }

    private static func precedingWord(
        from source: any FileContentSource, endingAt offset: Int64, context: String
    ) async throws -> String {
        var cursor = offset
        var leadingBytes: [UInt8] = []
        var pendingCharacter = context
        var pieces: [String] = []
        while true {
            try Task.checkCancellation()
            let start = max(0, cursor - 4096)
            var bytes = Array(try await source.read(at: start, count: Int(cursor - start)))
            bytes.append(contentsOf: leadingBytes)
            cursor = start
            var split = 0
            if start > 0 {
                while split < min(3, bytes.count) && bytes[split] & 0xC0 == 0x80 { split += 1 }
            }
            leadingBytes = Array(bytes.prefix(split))
            let decoded = String(decoding: bytes.dropFirst(split), as: UTF8.self)
            let combined = decoded + pendingCharacter
            guard !combined.isEmpty else { continue }
            let trustedStart = start == 0 ? combined.startIndex : combined.index(after: combined.startIndex)
            if let stop = combined[trustedStart...].lastIndex(where: { !WordSelectionRange.isWord($0) }) {
                pieces.append(String(combined[combined.index(after: stop)...]))
                return pieces.reversed().joined()
            }
            pieces.append(String(combined[trustedStart...]))
            if start == 0 { return pieces.reversed().joined() }
            pendingCharacter = String(combined[..<trustedStart])
        }
    }
}
