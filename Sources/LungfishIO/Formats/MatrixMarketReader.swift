// MatrixMarketReader.swift - One streaming pass over a Matrix Market matrix of whole counts (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Cell Ranger and STARsolo write a single-cell matrix as Matrix Market text, features by barcodes, plain or gzip. LGE reads
// only `%%MatrixMarket matrix coordinate integer general` and refuses every other header and every value that is not an
// unsigned decimal integer, since a rounded count would be a false one (`docs/formats/rnaseq-bundle.md`, Single cell,
// `SCR/rulings/ARCH-SCHEMA-SPIKE.md` B5). The reader holds one chunk of text and one batch of entries, never the matrix.
// A gzip file is read through `GzipChildStream`, so the child runs on ToolProcess and is reaped on close.

import Foundation

/// The size line of a matrix: rows (features), columns (barcodes) and entries.
public struct MatrixMarketSize: Equatable, Sendable {
    public var rows: Int
    public var columns: Int
    public var entries: Int

    public init(rows: Int, columns: Int, entries: Int) {
        self.rows = rows
        self.columns = columns
        self.entries = entries
    }
}

/// Why a matrix was refused, in words a person can act on. Every case is of the field `matrix`.
public enum MatrixMarketError: Error, Equatable, LocalizedError, Sendable {
    /// The header or a value holds another kind of number than whole counts.
    case notWholeCounts(kind: String, detail: String)
    case noHeader(file: String)
    case invalidSizeLine(file: String, line: String)
    case invalidEntry(file: String, lineNumber: Int, line: String)
    case indexOutOfRange(file: String, lineNumber: Int, row: Int, column: Int, size: MatrixMarketSize)
    case entryCountDiffers(file: String, stated: Int, found: Int?)
    case shortGzip(file: String, reason: String)
    case unreadable(file: String, reason: String)

    public var field: String { "matrix" }

    public var errorDescription: String? {
        switch self {
        case .notWholeCounts(let kind, let detail):
            return "This matrix holds \(kind) values (\(detail)), and LGE counts whole unique UMIs a cell. "
                + "Import the folder's integer matrix, such as Solo.out/Gene/filtered/matrix.mtx."
        case .noHeader(let file):
            return "\(file) does not start with the header \(MatrixMarketReader.header), so it is no matrix LGE reads."
        case .invalidSizeLine(let file, let line):
            return "The size line of \(file) reads \(line), not the rows, columns and entries as three whole numbers."
        case .invalidEntry(let file, let lineNumber, let line):
            return "Line \(lineNumber) of \(file) reads \(line), not a row, a column and a count."
        case .indexOutOfRange(let file, let lineNumber, let row, let column, let size):
            return "Line \(lineNumber) of \(file) names row \(row) and column \(column), outside the \(size.rows) rows and \(size.columns) columns of its size line."
        case .entryCountDiffers(let file, let stated, let found):
            return "\(file) states \(stated) entries in its size line and holds \(found.map(String.init) ?? "more"), so the file is cut short or was changed. Copy it again from the tool's output."
        case .shortGzip(let file, let reason):
            return "\(file) ends before its gzip stream does, so the file is cut short. Copy it again from the tool's output. gzip said: \(reason)"
        case .unreadable(let file, let reason):
            return "\(file) could not be read, because \(reason)."
        }
    }
}

/// One batch of entries, rows and columns from 1 as the file gives them. The arrays keep their capacity between batches.
public struct MatrixMarketBatch: Sendable {
    public let capacity: Int
    public private(set) var rows: [Int]
    public private(set) var columns: [Int]
    public private(set) var values: [UInt64]
    public var count: Int { values.count }

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        rows = []
        columns = []
        values = []
        rows.reserveCapacity(self.capacity)
        columns.reserveCapacity(self.capacity)
        values.reserveCapacity(self.capacity)
    }

    mutating func removeAll() {
        rows.removeAll(keepingCapacity: true)
        columns.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
    }

    mutating func append(row: Int, column: Int, value: UInt64) {
        rows.append(row)
        columns.append(column)
        values.append(value)
    }
}

/// Reads one matrix once, from its header to its last entry, through ``next(_:)``.
///
/// The header and the size line are read when the reader opens, so a refused header costs one chunk. Each batch
/// is checked as it is parsed, and the call that finds the end checks gzip's exit and the entry count, so a matrix
/// read to its end with no throw is whole. Call ``close()`` to stop early. Used from one thread at a time.
public final class MatrixMarketReader {
    /// The one header LGE reads.
    public static let header = "%%MatrixMarket matrix coordinate integer general"
    static let chunkSize = 1 << 20

    public let url: URL
    public let isGzip: Bool
    public private(set) var size = MatrixMarketSize(rows: 0, columns: 0, entries: 0)
    /// The `%` comment lines between the header and the size line, trimmed, such as the `%metadata_json:` line in
    /// which Cell Ranger states its version.
    public private(set) var comments: [String] = []

    private let source: MatrixMarketByteSource
    private var buffer: [UInt8] = []
    private var position = 0
    private var sourceEnded = false
    private var finished = false
    private var lineNumber = 0
    private var found = 0
    private var name: String { url.lastPathComponent }

    public init(url: URL) throws {
        self.url = url
        isGzip = try Self.isGzipFile(url)
        source = try MatrixMarketByteSource(url: url, gzip: isGzip)
        do {
            try readHeader()
        } catch {
            source.close()
            throw error
        }
    }

    deinit { source.close() }

    /// Stops gzip when it still runs. Safe to call twice.
    public func close() {
        finished = true
        source.close()
    }

    /// Fills `batch` with the next entries and returns true, or checks the end and returns false.
    public func next(_ batch: inout MatrixMarketBatch) throws -> Bool {
        batch.removeAll()
        guard !finished else { return false }
        do {
            while batch.count < batch.capacity {
                guard let range = try nextLine() else { break }
                lineNumber += 1
                try buffer.withUnsafeBufferPointer { try parseEntry($0, range, into: &batch) }
            }
        } catch let error as MatrixMarketError {
            // A cut gzip ends in a part of a line, so a refused last line of a gzip stream is gzip's failure first.
            if isGzip, sourceEnded, let short = gzipFailure() { throw short }
            throw error
        }
        if batch.count > 0 { return true }
        finished = true
        if let short = gzipFailure() { throw short }
        guard found == size.entries else {
            throw MatrixMarketError.entryCountDiffers(file: name, stated: size.entries, found: found)
        }
        return false
    }

    /// Every line of a plain or gzip text file, such as `features.tsv.gz` or `barcodes.tsv`, held in memory.
    public static func textLines(of url: URL) throws -> [String] {
        let data: Data
        do {
            data = try isGzipFile(url) ? GzipTool.decompressedData(of: url) : Data(contentsOf: url)
        } catch {
            throw MatrixMarketError.unreadable(file: url.lastPathComponent, reason: Self.describe(error))
        }
        // Swift reads "\r\n" as one Character that is not "\n", so the split takes every line break, as the import's reader does.
        var lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map(String.init)
    }

    /// Whether `url` starts with gzip's two magic bytes.
    public static func isGzipFile(_ url: URL) throws -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: 2) == Data([0x1f, 0x8b])
        } catch {
            throw MatrixMarketError.unreadable(file: url.lastPathComponent, reason: describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func gzipFailure() -> MatrixMarketError? {
        do {
            try source.finish()
            return nil
        } catch {
            return .shortGzip(file: name, reason: Self.describe(error))
        }
    }

    private func text(_ range: Range<Int>) -> String {
        String(decoding: buffer[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The next line without its newline, as a range of `buffer` that stays valid until the next call.
    private func nextLine() throws -> Range<Int>? {
        while true {
            if position < buffer.count {
                let start = position
                let newline: Int? = buffer.withUnsafeBufferPointer { bytes in
                    guard let base = bytes.baseAddress, let hit = memchr(base + start, 0x0a, bytes.count - start) else { return nil }
                    return base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                }
                if let newline {
                    position = newline + 1
                    return start..<newline
                }
            }
            if sourceEnded {
                guard position < buffer.count else { return nil }
                defer { position = buffer.count }
                return position..<buffer.count
            }
            if position > 0 {
                buffer.removeSubrange(0..<position)
                position = 0
            }
            let chunk = try source.read()
            if chunk.isEmpty { sourceEnded = true } else { buffer.append(contentsOf: chunk) }
        }
    }

    private static func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0d }

    /// Reads the header, the comment lines and the size line.
    private func readHeader() throws {
        guard let first = try nextLine() else { throw MatrixMarketError.noHeader(file: name) }
        lineNumber = 1
        let banner = text(first)
        let tokens = banner.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.lowercased() }
        guard tokens.count == 5, tokens[0] == "%%matrixmarket", tokens[1] == "matrix" else {
            throw MatrixMarketError.noHeader(file: name)
        }
        for (token, expected) in zip(tokens.dropFirst(2), ["coordinate", "integer", "general"]) where token != expected {
            throw MatrixMarketError.notWholeCounts(kind: token, detail: banner)
        }
        while let range = try nextLine() {
            lineNumber += 1
            let line = text(range)
            if line.isEmpty { continue }
            if line.hasPrefix("%") {
                comments.append(line)
                continue
            }
            let numbers = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard numbers.count == 3, numbers.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let rows = Int(numbers[0]), let columns = Int(numbers[1]), let entries = Int(numbers[2]) else {
                throw MatrixMarketError.invalidSizeLine(file: name, line: line)
            }
            size = MatrixMarketSize(rows: rows, columns: columns, entries: entries)
            return
        }
        throw MatrixMarketError.invalidSizeLine(file: name, line: "nothing")
    }

    /// Parses one entry line of three unsigned decimal fields, or skips a blank line.
    private func parseEntry(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, into batch: inout MatrixMarketBatch) throws {
        var fields: (UInt64, UInt64, UInt64) = (0, 0, 0)
        var count = 0
        var index = range.lowerBound
        let end = range.upperBound
        while index < end {
            if Self.isSpace(bytes[index]) {
                index += 1
                continue
            }
            var value: UInt64 = 0
            var digits = 0
            var stray: UInt8 = 0
            while index < end, !Self.isSpace(bytes[index]) {
                let digit = bytes[index] &- 0x30
                if digit < 10 {
                    value = value &* 10 &+ UInt64(digit)
                    digits += 1
                } else if stray == 0 {
                    stray = bytes[index]
                }
                index += 1
            }
            if stray != 0 || digits == 0 || digits > 18 {
                guard count == 2 else { throw MatrixMarketError.invalidEntry(file: name, lineNumber: lineNumber, line: text(range)) }
                let kind: String
                switch stray {
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"): kind = "decimal"
                case UInt8(ascii: "-"), UInt8(ascii: "+"): kind = "signed"
                default: kind = "non-integer"
                }
                throw MatrixMarketError.notWholeCounts(kind: kind, detail: "line \(lineNumber) of \(name) reads \(text(range))")
            }
            switch count { case 0: fields.0 = value; case 1: fields.1 = value; case 2: fields.2 = value; default: break }
            count += 1
        }
        if count == 0 { return }
        guard count == 3 else { throw MatrixMarketError.invalidEntry(file: name, lineNumber: lineNumber, line: text(range)) }
        let row = Int(fields.0)
        let column = Int(fields.1)
        guard row >= 1, row <= size.rows, column >= 1, column <= size.columns else {
            throw MatrixMarketError.indexOutOfRange(file: name, lineNumber: lineNumber, row: row, column: column, size: size)
        }
        found += 1
        guard found <= size.entries else { throw MatrixMarketError.entryCountDiffers(file: name, stated: size.entries, found: nil) }
        batch.append(row: row, column: column, value: fields.2)
    }
}

/// The bytes of a matrix file, read as given or through one gzip child.
final class MatrixMarketByteSource {
    private var handle: FileHandle?
    private var gzip: GzipChildStream?
    private let name: String

    init(url: URL, gzip isGzip: Bool) throws {
        name = url.lastPathComponent
        do {
            if isGzip { gzip = try GzipChildStream(decompressing: url) } else { handle = try FileHandle(forReadingFrom: url) }
        } catch {
            throw MatrixMarketError.unreadable(file: name, reason: MatrixMarketReader.describe(error))
        }
    }

    func read() throws -> Data {
        if let gzip { return gzip.readChunk(upTo: MatrixMarketReader.chunkSize) }
        do {
            // FileHandle autoreleases each chunk it returns. An import reads the whole matrix in one job that never
            // returns to a run loop, so the thread's own pool would drain only when the read ends and every chunk would
            // stay alive until then. Each chunk gets its own pool, as the gzip stream's chunks do.
            return try autoreleasepool { try handle?.read(upToCount: MatrixMarketReader.chunkSize) ?? Data() }
        } catch {
            throw MatrixMarketError.unreadable(file: name, reason: MatrixMarketReader.describe(error))
        }
    }

    /// Waits for gzip once its output has ended and throws its failure. A plain file has none.
    func finish() throws {
        guard let gzip else { return }
        self.gzip = nil
        try gzip.finish()
    }

    func close() {
        gzip?.close()
        gzip = nil
        try? handle?.close()
        handle = nil
    }
}
