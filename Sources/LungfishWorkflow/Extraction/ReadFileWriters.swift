// ReadFileWriters.swift - The joins and conversions that write read files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - Streaming publication

/// A source file of a join or a conversion that cannot be opened or read.
/// The error names the file, so a caller never gets a joined file that is
/// missing the reads of one source (Phase 2.10 lane S31, panel BIO 2).
enum ReadFileWriterError: Error, LocalizedError, Equatable {
    case unreadableSource(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unreadableSource(let path, let reason):
            let cause = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
            return "Cannot read \(path): \(cause). Nothing was written."
        }
    }
}

/// The streaming core of the writers that put read files on disk.
///
/// Each writer streams into the hidden stage file of ``DurableReplace`` and
/// names the result only when it is whole and synced, so the final name holds
/// a whole old or new file at every step. A failed write, a full disk among
/// them, is a thrown error, where `FileHandle.write(_:)` raised an
/// Objective-C exception that Swift cannot catch. A source is read with the
/// throwing `FileHandle.read(upToCount:)` in chunks, so a large input is never
/// held whole and a read error is a thrown ``ReadFileWriterError``.
enum ReadFileWriters {
    /// The most bytes of a source held in memory at once while joining.
    static let chunkSize = 4 * 1024 * 1024

    /// Streams `sources` in order into `destination`, byte for byte but for one
    /// rule. A member whose bytes do not end in a line break gets one before
    /// the next member that starts a record (`@` or `>`), so no record runs
    /// into the next member's header and the joined file holds the sum of the
    /// members' reads. That is S12's rule for a plain member
    /// (`ResolvedSequenceInputs`, Phase 2.9), held to the place where it
    /// changes a read (Phase 2.13 lane 13.15, SW5 under BIO's ruling). Members
    /// that end in line breaks, gzip members, which start with no record, and
    /// the last member keep their bytes.
    static func join(_ sources: [URL], into destination: URL) throws {
        try publish(destination) { stage in
            var lastByte: UInt8?
            for source in sources {
                lastByte = try append(source, to: stage, after: lastByte) ?? lastByte
            }
        }
    }

    /// The first bytes of a FASTQ and of a FASTA record.
    private static let recordStarts: Set<UInt8> = [UInt8(ascii: "@"), UInt8(ascii: ">")]

    /// Publishes the bytes that `body` streams as `destination`, swapping out
    /// any regular file the name holds, and returns what `body` returns. When
    /// `body` throws, the name keeps its old file and no stage file is left
    /// in the folder.
    @discardableResult
    static func publish<Value>(
        _ destination: URL,
        writing body: (DurableReplace.StageWriter) throws -> Value
    ) throws -> Value {
        var result: Value?
        try DurableReplace.replace(
            named: destination.lastPathComponent,
            in: destination.deletingLastPathComponent(),
            recovery: .none
        ) { stage in
            result = try body(stage)
        }
        guard let result else {
            // `replace` runs its body exactly once before it returns.
            throw DurableReplace.ReplaceError.systemFailure(path: destination.path, operation: "run the writer", code: EIO)
        }
        return result
    }

    /// Streams `source` into `stage` in chunks and returns its last byte, nil
    /// for an empty source. When `previous`, the last byte written before it,
    /// is no line break and `source` starts a record, a line break goes first.
    @discardableResult
    static func append(_ source: URL, to stage: DurableReplace.StageWriter, after previous: UInt8? = nil) throws -> UInt8? {
        let input = try openForReading(source)
        defer { try? input.close() }
        let lineBreak = UInt8(ascii: "\n")
        var last: UInt8?
        while let chunk = try readChunk(of: input, from: source), !chunk.isEmpty {
            if last == nil, let previous, previous != lineBreak, let first = chunk.first, recordStarts.contains(first) {
                try stage.write(Data([lineBreak]))
            }
            try stage.write(chunk)
            last = chunk.last
        }
        return last
    }

    /// Opens `source`, or throws ``ReadFileWriterError/unreadableSource(path:reason:)``.
    static func openForReading(_ source: URL) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: source)
        } catch {
            throw ReadFileWriterError.unreadableSource(path: source.path, reason: error.localizedDescription)
        }
    }

    /// The next chunk of `handle`, `nil` at the end of the file, or a thrown
    /// ``ReadFileWriterError/unreadableSource(path:reason:)``.
    static func readChunk(of handle: FileHandle, from source: URL, upTo count: Int = chunkSize) throws -> Data? {
        do {
            return try handle.read(upToCount: count)
        } catch {
            throw ReadFileWriterError.unreadableSource(path: source.path, reason: error.localizedDescription)
        }
    }
}

// MARK: - Classifier read resolver

extension ClassifierReadResolver {
    func concatenateFiles(_ sources: [URL], into destination: URL) throws {
        try ReadFileWriters.join(sources, into: destination)
    }

    /// FASTQ → FASTA line-by-line conversion. Drops quality lines.
    func convertFASTQToFASTA(input: URL, output: URL) throws {
        let inHandle = try ReadFileWriters.openForReading(input)
        defer { try? inHandle.close() }

        try ReadFileWriters.publish(output) { stage in
            // Stream line-by-line. We use a simple buffered line reader.
            let reader = LineReader(handle: inHandle, source: input)
            var pending = Data()
            var lineIndex = 0
            while let line = try reader.nextLine() {
                let mod = lineIndex % 4
                if mod == 0 {
                    // Header line: convert leading @ to >
                    if line.first == 0x40 /* @ */ {
                        pending.append(0x3E /* > */)
                        pending.append(line.dropFirst())
                    } else {
                        pending.append(line)
                    }
                    pending.append(0x0A)
                } else if mod == 1 {
                    pending.append(line)
                    pending.append(0x0A)
                }
                // mod == 2 (+) and mod == 3 (quality) are discarded.
                lineIndex += 1
                if pending.count >= ReadFileWriters.chunkSize {
                    try stage.write(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty { try stage.write(pending) }
        }
    }
}

// MARK: - Batch importer

extension FASTQBatchImporter {
    /// Concatenates multiple FASTQ files into a single destination file.
    ///
    /// Each source streams in chunks, so a multi-gigabyte FASTQ is never held
    /// whole. A source that cannot be opened or read is a thrown
    /// ``ReadFileWriterError`` that names it, where the base skipped it and
    /// wrote a joined file with fewer reads than its sources held (panel BIO 2).
    /// The joined file is published whole and synced, and the name keeps its
    /// old file when the join fails.
    static func concatenateFiles(_ sources: [URL], to destination: URL) throws {
        try ReadFileWriters.join(sources, into: destination)
    }
}

// MARK: - LineReader (private helper)

/// A minimal line reader for FASTQ → FASTA streaming. Not a general-purpose
/// line reader — it assumes LF line endings.
fileprivate final class LineReader {
    private let handle: FileHandle
    private let source: URL
    private var buffer = Data()
    private let chunkSize = 1 << 20

    init(handle: FileHandle, source: URL) {
        self.handle = handle
        self.source = source
    }

    /// The next line without its line break, `nil` at the end of the file.
    /// A read error is a thrown ``ReadFileWriterError``.
    func nextLine() throws -> Data? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex..<buffer.index(after: newlineIndex))
                return line
            }
            let chunk = try ReadFileWriters.readChunk(of: handle, from: source, upTo: chunkSize) ?? Data()
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let line = buffer
                buffer = Data()
                return line
            }
            buffer.append(chunk)
        }
    }
}
