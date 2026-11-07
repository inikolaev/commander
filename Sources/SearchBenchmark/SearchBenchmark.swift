import Foundation
@_spi(Benchmark) import EditorCore
@_spi(Benchmark) import FileManagerCore
@_spi(Benchmark) import TextSearchCore

// JSON Lines on stdout; diagnostics and usage go to stderr. Timings use a
// monotonic clock and exclude document construction and output serialization.
private struct FixtureManifest: Decodable {
    struct Case: Decodable {
        let name: String
        let query: String
        let expectedByteOffset: Int64?
        let expectedLength: Int
    }
    let file: String
    let sizeBytes: Int64
    let cases: [Case]
}

private struct Options {
    enum Surface: String { case viewer, editor }
    enum Operation: String { case search, scan }
    let file: URL
    let expectedFileBytes: Int64?
    let surface: Surface
    let operation: Operation
    let query: String?
    let caseName: String?
    let expectedOffset: Int64?
    let expectedLength: Int?
    let direction: SearchDirection
    let directionName: String
    let caseSensitive: Bool
    let wholeWord: Bool
    let matcher: ASCIILiteralMatcher
    let matcherName: String
    let anchor: Int64?
    let iterations: Int
    let chunkSize: Int

    static func parse(_ arguments: [String]) throws -> Self {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard key.hasPrefix("--") else { throw BenchmarkError("Unexpected argument: \(key)") }
            if ["--case-sensitive", "--whole-word"].contains(key) {
                guard flags.insert(key).inserted else { throw BenchmarkError("Repeated option: \(key)") }
                index += 1
                continue
            }
            guard index + 1 < arguments.count, values[key] == nil else {
                throw BenchmarkError("Missing value or repeated option: \(key)")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        let allowed: Set<String> = ["--file", "--surface", "--operation", "--query", "--manifest", "--case", "--expect-offset", "--expect-length", "--direction", "--anchor", "--iterations", "--chunk-size", "--matcher"]
        guard Set(values.keys).isSubset(of: allowed) else {
            throw BenchmarkError("Unknown option: \(Set(values.keys).subtracting(allowed).sorted().joined(separator: ", "))")
        }
        guard let rawSurface = values["--surface"], let surface = Surface(rawValue: rawSurface) else {
            throw BenchmarkError("--surface must be viewer or editor")
        }
        guard let rawOperation = values["--operation"], let operation = Operation(rawValue: rawOperation) else {
            throw BenchmarkError("--operation must be search or scan")
        }
        let manifest: FixtureManifest?
        if let path = values["--manifest"] {
            manifest = try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else { manifest = nil }
        guard values["--case"] == nil || manifest != nil else { throw BenchmarkError("--case requires --manifest") }
        let selected = manifest?.cases.first { $0.name == values["--case"] }
        if let name = values["--case"], selected == nil { throw BenchmarkError("Unknown fixture case: \(name)") }
        let filePath = values["--file"] ?? manifest?.file
        guard let filePath else { throw BenchmarkError("Provide --file or --manifest") }
        let directionName = values["--direction"] ?? "forward"
        let direction: SearchDirection
        switch directionName {
        case "forward": direction = .forward
        case "backward": direction = .backward
        default: throw BenchmarkError("--direction must be forward or backward")
        }
        let matcherName = values["--matcher"] ?? "foundation"
        let matcher: ASCIILiteralMatcher
        switch matcherName {
        case "foundation": matcher = .foundation
        case "darwin-memmem": matcher = .darwinMemmem
        default: throw BenchmarkError("--matcher must be foundation or darwin-memmem")
        }
        let iterations = try positiveInt(values["--iterations"] ?? "3", "--iterations")
        let chunkSize = try positiveInt(values["--chunk-size"] ?? "65536", "--chunk-size")
        let anchor = try values["--anchor"].map { try nonnegativeInt64($0, "--anchor") }
        let explicitLength = try values["--expect-length"].map { try nonnegativeInt($0, "--expect-length") }
        let expectedLength = explicitLength ?? selected?.expectedLength
        let explicitOffset = try values["--expect-offset"].map { try nonnegativeInt64($0, "--expect-offset") }
        let expectedOffset = explicitOffset ?? (explicitLength == 0 ? nil : selected?.expectedByteOffset)
        let query = values["--query"] ?? selected?.query
        if operation == .search && (query == nil || query!.isEmpty) { throw BenchmarkError("Search requires a nonempty --query or --case") }
        if operation == .scan && (values["--query"] != nil || values["--case"] != nil) { throw BenchmarkError("Scan takes no query or case") }
        if values["--expect-offset"] != nil && expectedLength == nil { throw BenchmarkError("--expect-offset requires --expect-length") }
        if flags.contains("--whole-word"), selected != nil, explicitLength == nil {
            throw BenchmarkError("--whole-word with --case requires an explicit --expect-length (0 for exhausted)")
        }
        if anchor != nil, selected != nil, explicitLength == nil {
            throw BenchmarkError("--anchor with --case requires an explicit --expect-length (0 for exhausted)")
        }
        return Self(file: URL(fileURLWithPath: filePath), expectedFileBytes: manifest?.sizeBytes,
                    surface: surface, operation: operation,
                    query: query, caseName: values["--case"], expectedOffset: expectedOffset,
                    expectedLength: expectedLength, direction: direction, directionName: directionName,
                    caseSensitive: flags.contains("--case-sensitive"), wholeWord: flags.contains("--whole-word"),
                    matcher: matcher, matcherName: matcherName,
                    anchor: anchor, iterations: iterations, chunkSize: chunkSize)
    }

    private static func positiveInt(_ value: String, _ key: String) throws -> Int {
        guard let parsed = Int(value), parsed > 0 else { throw BenchmarkError("\(key) must be a positive integer") }
        return parsed
    }
    private static func nonnegativeInt(_ value: String, _ key: String) throws -> Int {
        guard let parsed = Int(value), parsed >= 0 else { throw BenchmarkError("\(key) must be a nonnegative integer") }
        return parsed
    }
    private static func nonnegativeInt64(_ value: String, _ key: String) throws -> Int64 {
        guard let parsed = Int64(value), parsed >= 0 else { throw BenchmarkError("\(key) must be a nonnegative integer") }
        return parsed
    }
}

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct Record: Encodable {
    let kind: String
    let surface: String
    let operation: String
    let file: String
    let fileBytes: Int64
    let chunkSize: Int
    let documentLength: Int?
    let iteration: Int?
    let elapsedNs: UInt64
    let query: String?
    let caseName: String?
    let direction: String?
    let caseSensitive: Bool?
    let wholeWord: Bool?
    let matcher: String
    let anchor: Int64?
    let result: String?
    let offset: Int64?
    let length: Int?
    let checksum: String?
    let bytesTraversed: Int64?
    let expectedOffset: Int64?
    let expectedLength: Int?
    let correct: Bool?
}

private func emit(_ record: Record) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var data = try encoder.encode(record)
    data.append(10)
    FileHandle.standardOutput.write(data)
}

private func monotonic() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

private func fnv(_ bytes: some Sequence<UInt8>, seed: UInt64 = 0xcbf29ce484222325) -> UInt64 {
    var hash = seed
    for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return hash
}

private func checksum(_ value: String) -> String { String(format: "%016llx", fnv(value.utf8)) }

private func sampleChecksum(_ hash: UInt64, first: UInt8, last: UInt8, count: Int) -> UInt64 {
    (hash &* 0x100000001b3) ^ UInt64(first) ^ (UInt64(last) << 8) ^ UInt64(count)
}

@inline(never)
private func scanViewer(_ source: LocalFileContentSource, size: Int64, chunkSize: Int,
                        direction: SearchDirection) async throws -> (Int64, UInt64) {
    var cursor: Int64 = direction == .forward ? 0 : size
    var traversed: Int64 = 0
    var hash: UInt64 = 0xcbf29ce484222325
    while traversed < size {
        let count = Int(min(Int64(chunkSize), size - traversed))
        let start = direction == .forward ? cursor : cursor - Int64(count)
        let data = try await source.read(at: start, count: count)
        guard !data.isEmpty else { throw BenchmarkError("Viewer source ended before metadata size") }
        hash = sampleChecksum(hash, first: data.first!, last: data.last!, count: data.count)
        traversed += Int64(data.count)
        cursor = direction == .forward ? start + Int64(data.count) : start
    }
    return (traversed, hash)
}

@main @MainActor
private enum SearchBenchmark {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("SearchBenchmark: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        let size = Int64((try FileManager.default.attributesOfItem(atPath: options.file.path)[.size] as? NSNumber)?.int64Value ?? -1)
        guard size >= 0 else { throw BenchmarkError("Cannot determine file size") }
        if let expected = options.expectedFileBytes, expected != size {
            throw BenchmarkError("File size \(size) differs from manifest size \(expected)")
        }
        let setupStart = monotonic()
        let viewerSource: LocalFileContentSource?
        let snapshot: EditorSearchSnapshot?
        if options.surface == .viewer {
            viewerSource = try LocalFileContentSource(url: options.file)
            snapshot = nil
        } else {
            let file = try EditorFile.open(options.file)
            let document = EditorDocuments.make(file: file)
            snapshot = document.makeSearchSnapshot()
            viewerSource = nil
        }
        let setupNs = monotonic() - setupStart
        let resolvedAnchor: Int64? = options.operation == .search
            ? (options.anchor ?? (options.direction == .forward ? 0
                : (snapshot.map { Int64(max(0, $0.length - 1)) } ?? max(0, size - 1))))
            : nil
        let query = options.query.map {
            TextSearchQuery(text: $0, caseSensitive: options.caseSensitive, wholeWord: options.wholeWord)
        }
        let viewerSearch = viewerSource.map { ViewerSearchSource(source: $0, chunkSize: options.chunkSize) }
        try emit(Record(kind: "setup", surface: options.surface.rawValue, operation: options.operation.rawValue,
                        file: options.file.path, fileBytes: size, chunkSize: options.chunkSize,
                        documentLength: snapshot?.length, iteration: nil, elapsedNs: setupNs,
                        query: options.query, caseName: options.caseName, direction: options.directionName,
                        caseSensitive: options.caseSensitive, wholeWord: options.wholeWord,
                        matcher: options.matcherName, anchor: resolvedAnchor,
                        result: nil, offset: nil, length: nil, checksum: nil, bytesTraversed: nil,
                        expectedOffset: options.expectedOffset, expectedLength: options.expectedLength, correct: nil))

        for iteration in 1...options.iterations {
            let start = monotonic()
            var result: String
            var offset: Int64?
            var length: Int?
            var scanDigest: UInt64?
            var traversed: Int64?
            if options.operation == .scan {
                if let source = viewerSource {
                    let scanned = try await scanViewer(source, size: size, chunkSize: options.chunkSize,
                                                       direction: options.direction)
                    traversed = scanned.0
                    scanDigest = scanned.1
                } else {
                    let scanned = snapshot!.scanBlocks(direction: options.direction, chunkSize: options.chunkSize)
                    traversed = Int64(scanned.units)
                    scanDigest = scanned.checksum
                }
                result = "scanned"
            } else {
                if let viewerSearch {
                    let found = try await viewerSearch.search(query!, direction: options.direction,
                                                               fromByteOffset: resolvedAnchor!, matcher: options.matcher)
                    switch found {
                    case .found(let hit): result = "found"; offset = hit.lowerBound; length = Int(hit.upperBound - hit.lowerBound)
                    case .exhausted: result = "exhausted"
                    case .cancelled: result = "cancelled"
                    case .sourceChanged: result = "sourceChanged"
                    }
                } else {
                    let value = snapshot!
                    let anchor = resolvedAnchor!
                    guard anchor <= Int.max else { throw BenchmarkError("Editor anchor exceeds Int.max") }
                    let found = value.search(query!, direction: options.direction,
                                             fromUTF16Offset: Int(anchor), chunkSize: options.chunkSize,
                                             matcher: options.matcher)
                    switch found {
                    case .found(let hit): result = "found"; offset = Int64(hit.exactRange.location); length = hit.exactRange.length
                    case .exhausted: result = "exhausted"
                    case .cancelled: result = "cancelled"
                    }
                }
            }
            let elapsed = monotonic() - start
            let digest = scanDigest.map { String(format: "%016llx", $0) }
                ?? checksum("\(result):\(offset.map(String.init) ?? "-"):\(length.map(String.init) ?? "-")")
            let correct: Bool
            if options.operation == .scan { correct = traversed == (options.surface == .viewer ? size : Int64(snapshot!.length)) }
            else if let expected = options.expectedOffset { correct = result == "found" && offset == expected && length == options.expectedLength }
            else if options.expectedLength != nil { correct = result == "exhausted" }
            else { correct = result == "found" || result == "exhausted" }
            try emit(Record(kind: "iteration", surface: options.surface.rawValue, operation: options.operation.rawValue,
                            file: options.file.path, fileBytes: size, chunkSize: options.chunkSize,
                            documentLength: snapshot?.length, iteration: iteration, elapsedNs: elapsed,
                            query: options.query, caseName: options.caseName, direction: options.directionName,
                            caseSensitive: options.caseSensitive, wholeWord: options.wholeWord,
                            matcher: options.matcherName, anchor: resolvedAnchor,
                            result: result, offset: offset, length: length, checksum: digest,
                            bytesTraversed: traversed, expectedOffset: options.expectedOffset,
                            expectedLength: options.expectedLength, correct: correct))
            if !correct { throw BenchmarkError("Incorrect result in iteration \(iteration)") }
        }
    }
}
