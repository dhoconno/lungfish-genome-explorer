// GzipSupport.swift - Gzip decompression support for file reading
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner: File Format Expert (Role 06)

import Foundation
import Compression

// MARK: - GzipError

/// Errors that can occur during gzip operations.
public enum GzipError: Error, LocalizedError, Sendable {
    /// File not found
    case fileNotFound(URL)

    /// Invalid gzip format (bad magic bytes)
    case invalidFormat

    /// Decompression failed
    case decompressionFailed(String)

    /// File is empty
    case emptyFile

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "Gzip file not found: \(url.path)"
        case .invalidFormat:
            return "Invalid gzip format (expected magic bytes 0x1f 0x8b)"
        case .decompressionFailed(let message):
            return "Gzip decompression failed: \(message)"
        case .emptyFile:
            return "Gzip file is empty"
        }
    }
}

// MARK: - GzipInputStream

/// An async stream that reads and decompresses gzip files line by line.
///
/// Uses Apple's Compression framework for efficient decompression.
///
/// ## Example
/// ```swift
/// let stream = try GzipInputStream(url: gzipFile)
/// for try await line in stream.lines() {
///     print(line)
/// }
/// ```
public final class GzipInputStream: Sendable {

    /// The gzip magic bytes
    private static let gzipMagic: [UInt8] = [0x1f, 0x8b]

    /// URL of the gzip file
    public let url: URL

    /// Creates a gzip input stream for the specified file.
    ///
    /// - Parameter url: URL of the gzip file
    /// - Throws: `GzipError` if the file cannot be opened or is invalid
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GzipError.fileNotFound(url)
        }
        self.url = url
    }

    /// Returns an async sequence of lines from the decompressed file.
    ///
    /// Pull-based: each `next()` decompresses at most one more 1 MB chunk, so
    /// memory stays O(chunk) no matter how slowly the consumer iterates. The
    /// previous push-based implementation yielded into an unbounded
    /// `AsyncThrowingStream` buffer from a producer task, so a fast gzip and a
    /// slow consumer (per-read statistics) buffered the whole decompressed file
    /// in memory: on 2026-08-22 that took the app to 20 GB and out of memory.
    ///
    /// Handles both Unix (`\n`) and Windows (`\r\n`) line endings.
    ///
    /// - Returns: AsyncThrowingStream of String lines
    public func lines() -> AsyncThrowingStream<String, Error> {
        let box = LineSourceBox(url: url)
        return AsyncThrowingStream(unfolding: {
            if Task.isCancelled {
                box.close()
                return nil
            }
            do {
                return try box.next()
            } catch {
                box.close()
                throw error
            }
        })
    }

    /// Serial holder for the lazily started line source (the unfolding closure
    /// is `@Sendable`; the source is only ever touched by one iterator).
    private final class LineSourceBox: @unchecked Sendable {
        private let url: URL
        private var source: GzipLineSource?
        private var exhausted = false

        init(url: URL) { self.url = url }

        func next() throws -> String? {
            if exhausted { return nil }
            if source == nil {
                source = try GzipLineSource(url: url)
            }
            let line = try source?.next()
            if line == nil {
                exhausted = true
                close()
            }
            return line
        }

        func close() {
            source?.close()
            source = nil
        }
    }

    /// Synchronously iterates over decompressed lines.
    ///
    /// This shares the same line semantics as ``lines()`` while allowing
    /// synchronous parsers to transparently handle `.gz` files.
    func forEachLine(_ body: (String) throws -> Void) throws {
        try Self.validateGzipHeader(at: url)

        // gzip runs on ToolProcess. Leaving this function for any reason, a thrown body and a cancelled task
        // included, cancels the run, which ends the process tree and reaps it.
        let child = try GzipChildStream(decompressing: url)
        defer { child.close() }

        let chunkSize = 1_048_576 // 1 MB
        var partial = Data() // Leftover bytes from previous chunk (incomplete line)

        while true {
            try Task.checkCancellation()

            let chunk = child.readChunk(upTo: chunkSize)
            if chunk.isEmpty { break }

            partial.append(chunk)
            try Self.emitCompleteLines(from: &partial, body)
        }

        try Task.checkCancellation()
        try Self.emitFinalLine(from: partial, body)

        try child.finish()
    }

    /// Synchronously iterates over decompressed byte chunks.
    ///
    /// This is intended for high-volume parsers that can operate on bytes and
    /// should avoid allocating one `String` per input line.
    ///
    /// gzip runs on ToolProcess, so a caller in another module reads a gzip file in chunks without a `Process` of its
    /// own. Throws ``GzipError`` for a file that is not gzip, a gzip that cannot start and a run that exits nonzero,
    /// and `CancellationError` when the task is cancelled.
    public func forEachDecompressedChunk(
        chunkSize: Int = 1_048_576,
        _ body: (Data) throws -> Void
    ) throws {
        try Self.validateGzipHeader(at: url)

        // Leaving this function for any reason cancels the run, as in forEachLine.
        let child = try GzipChildStream(decompressing: url)
        defer { child.close() }

        while true {
            try Task.checkCancellation()

            let chunk = child.readChunk(upTo: chunkSize)
            if chunk.isEmpty { break }
            try body(chunk)
        }

        try Task.checkCancellation()
        try child.finish()
    }

    /// Decompresses the entire file and returns the content as a string.
    ///
    /// - Returns: Decompressed file content
    /// - Throws: `GzipError` if decompression fails
    public func readAll() async throws -> String {
        try readAllSync()
    }

    /// Decompresses the entire file and returns the content as a string.
    ///
    /// - Returns: Decompressed file content
    /// - Throws: `GzipError` if decompression fails
    public func readAllSync() throws -> String {
        let decompressedData = try decompressWithSystemGzip()

        guard let content = String(data: decompressedData, encoding: .utf8) else {
            throw GzipError.decompressionFailed("Invalid UTF-8 encoding")
        }

        return content
    }

    fileprivate static func emitCompleteLines(
        from buffer: inout Data,
        _ body: (String) throws -> Void
    ) throws {
        let newline = UInt8(ascii: "\n")
        let carriageReturn = UInt8(ascii: "\r")
        var lineStart = buffer.startIndex
        var searchStart = buffer.startIndex

        while searchStart < buffer.endIndex,
              let newlineIndex = buffer[searchStart...].firstIndex(of: newline) {
            var lineEnd = newlineIndex
            if lineEnd > lineStart {
                let previousIndex = buffer.index(before: lineEnd)
                if buffer[previousIndex] == carriageReturn {
                    lineEnd = previousIndex
                }
            }

            guard let line = String(bytes: buffer[lineStart..<lineEnd], encoding: .utf8) else {
                throw GzipError.decompressionFailed("Invalid UTF-8 encoding in chunk")
            }
            try body(line)

            lineStart = buffer.index(after: newlineIndex)
            searchStart = lineStart
        }

        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
    }

    fileprivate static func emitFinalLine(
        from buffer: Data,
        _ body: (String) throws -> Void
    ) throws {
        guard !buffer.isEmpty else { return }

        var lineEnd = buffer.endIndex
        if lineEnd > buffer.startIndex {
            let previousIndex = buffer.index(before: lineEnd)
            if buffer[previousIndex] == UInt8(ascii: "\r") {
                lineEnd = previousIndex
            }
        }

        guard let line = String(bytes: buffer[buffer.startIndex..<lineEnd], encoding: .utf8) else {
            throw GzipError.decompressionFailed("Invalid UTF-8 encoding in final chunk")
        }
        try body(line)
    }

    /// Validates that a file has a valid gzip header (magic bytes).
    ///
    /// Reads only the first 2 bytes — does not load the file into RAM.
    fileprivate static func validateGzipHeader(at url: URL) throws {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw GzipError.fileNotFound(url)
        }
        defer { try? fh.close() }
        guard let headerData = try? fh.read(upToCount: 2), headerData.count >= 2 else {
            throw GzipError.emptyFile
        }
        guard headerData[0] == gzipMagic[0], headerData[1] == gzipMagic[1] else {
            throw GzipError.invalidFormat
        }
    }

    /// Decompresses gzip/BGZF files using `/usr/bin/gzip -dc`.
    ///
    /// This path handles concatenated gzip members (e.g. BGZF blocks),
    /// which are common in indexed genomics files.
    /// Used by `readAll()` where the full content is needed in memory.
    private func decompressWithSystemGzip() throws -> Data {
        try Self.validateGzipHeader(at: url)
        return try GzipTool.decompressedData(of: url)
    }
}

// MARK: - Plain Text Input Stream

public extension FileHandle {
    /// Streams UTF-8 lines from this already-open handle's current offset.
    /// The caller retains ownership: this method advances the offset but never
    /// closes the handle, including on cancellation, read failure, or callback error.
    func forEachPlainTextLine(_ body: (String) throws -> Void) throws {
        let chunkSize = 1_048_576 // 1 MB
        var partial = Data()

        while true {
            try Task.checkCancellation()

            guard let chunk = try read(upToCount: chunkSize), !chunk.isEmpty else { break }

            partial.append(chunk)
            try GzipInputStream.emitCompleteLines(from: &partial, body)
        }

        try Task.checkCancellation()
        try GzipInputStream.emitFinalLine(from: partial, body)
    }
}

private struct PlainTextInputStream {
    let url: URL

    func forEachLine(_ body: (String) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = FileHandle(forReadingAtPath: url.path) else {
            throw GzipError.fileNotFound(url)
        }
        defer {
            try? handle.close()
        }

        try handle.forEachPlainTextLine(body)
    }

    func forEachChunk(
        chunkSize: Int = 1_048_576,
        _ body: (Data) throws -> Void
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = FileHandle(forReadingAtPath: url.path) else {
            throw GzipError.fileNotFound(url)
        }
        defer {
            try? handle.close()
        }

        while true {
            try Task.checkCancellation()

            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            try body(chunk)
        }
    }
}

// MARK: - URL Extension for Gzip Detection

// MARK: - GzipLineSource

/// Pull-based line reader over a `gzip -dc` pipe.
///
/// Reads one chunk per demand, keeps only the current partial line plus the
/// lines of the chunk that have not been handed out yet, and owns the
/// subprocess lifecycle. Not thread-safe: one consumer at a time.
final class GzipLineSource {
    private let url: URL
    private let chunkSize: Int
    private var child: GzipChildStream?
    private var partial = Data()
    private var pending: [String] = []
    private var pendingIndex = 0
    private var reachedEnd = false
    private var closed = false

    /// Number of chunks pulled from the pipe so far (test seam for backpressure).
    private(set) var chunksRead = 0

    init(url: URL, chunkSize: Int = 1_048_576) throws {
        try GzipInputStream.validateGzipHeader(at: url)
        self.url = url
        self.chunkSize = chunkSize
    }

    deinit { close() }

    /// The next decompressed line, or `nil` at end of file.
    func next() throws -> String? {
        if let line = dequeue() { return line }
        if reachedEnd || closed { return nil }
        let child = try startIfNeeded()

        while true {
            try Task.checkCancellation()
            let chunk = child.readChunk(upTo: chunkSize)
            if chunk.isEmpty {
                reachedEnd = true
                try GzipInputStream.emitFinalLine(from: partial) { pending.append($0) }
                partial.removeAll()
                try finishProcess()
                return dequeue()
            }
            chunksRead += 1
            partial.append(chunk)
            try GzipInputStream.emitCompleteLines(from: &partial) { pending.append($0) }
            if let line = dequeue() { return line }
        }
    }

    /// Stops gzip and releases the pipes. Safe to call repeatedly.
    ///
    /// Cancelling the run ends the process group and tree (SIGTERM, then SIGKILL after the grace period)
    /// and reaps it before this returns, so an abandoned iterator leaves no child and can never hang its owner.
    func close() {
        guard !closed else { return }
        closed = true
        child?.close()
        child = nil
        pending.removeAll()
        partial.removeAll()
    }

    private func dequeue() -> String? {
        guard pendingIndex < pending.count else {
            if !pending.isEmpty {
                pending.removeAll(keepingCapacity: true)
                pendingIndex = 0
            }
            return nil
        }
        let line = pending[pendingIndex]
        pendingIndex += 1
        if pendingIndex == pending.count {
            pending.removeAll(keepingCapacity: true)
            pendingIndex = 0
        }
        return line
    }

    private func startIfNeeded() throws -> GzipChildStream {
        if let child { return child }
        let started = try GzipChildStream(decompressing: url)
        child = started
        return started
    }

    /// Waits for gzip once its output reached end of file. ToolProcess drains stderr while gzip runs, so a child
    /// blocked on a full stderr pipe cannot hang this wait (the 2026-08-23 unit gate hung 54 minutes on one).
    private func finishProcess() throws {
        guard let child else { return }
        self.child = nil
        defer { child.close() }
        try child.finish()
    }
}

extension URL {
    /// File size in bytes, or 0 if the file doesn't exist or can't be read.
    public var fileSizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
    }

    /// Whether this URL points to a gzip-compressed file (based on extension).
    public var isGzipCompressed: Bool {
        pathExtension.lowercased() == "gz"
    }

    /// Iterates over lines synchronously, automatically handling gzip compression.
    ///
    /// This gives high-volume parsers backpressure that `AsyncThrowingStream` cannot
    /// provide, so decompressed FASTQ lines are not buffered ahead of consumers.
    public func forEachLineAutoDecompressing(_ body: (String) throws -> Void) throws {
        if isGzipCompressed {
            let stream = try GzipInputStream(url: self)
            try stream.forEachLine(body)
        } else {
            try PlainTextInputStream(url: self).forEachLine(body)
        }
    }

    /// Iterates over raw decompressed byte chunks, automatically handling gzip compression.
    public func forEachChunkAutoDecompressing(
        chunkSize: Int = 1_048_576,
        _ body: (Data) throws -> Void
    ) throws {
        if isGzipCompressed {
            let stream = try GzipInputStream(url: self)
            try stream.forEachDecompressedChunk(chunkSize: chunkSize, body)
        } else {
            try PlainTextInputStream(url: self).forEachChunk(chunkSize: chunkSize, body)
        }
    }

    /// Returns an async sequence of lines, automatically handling gzip compression.
    ///
    /// - Returns: AsyncThrowingStream of lines
    public func linesAutoDecompressing() -> AsyncThrowingStream<String, Error> {
        if isGzipCompressed {
            do {
                let stream = try GzipInputStream(url: self)
                return stream.lines()
            } catch {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: error)
                }
            }
        } else {
            // Use standard URL.lines for uncompressed files, pulled on demand so
            // the reader never outruns the consumer.
            let iterator = AsyncLineIteratorBox(self.lines.makeAsyncIterator())
            return AsyncThrowingStream(unfolding: {
                if Task.isCancelled { return nil }
                return try await iterator.next()
            })
        }
    }

    /// Returns an async line stream that iterates across multiple FASTQ files sequentially.
    ///
    /// Each file is decompressed (if gzipped) and its lines are yielded in order.
    /// Consumers see a single continuous stream across all files.
    ///
    /// - Parameter urls: Ordered list of FASTQ file URLs.
    /// - Returns: AsyncThrowingStream yielding lines from all files sequentially.
    public static func multiFileLinesAutoDecompressing(_ urls: [URL]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for url in urls {
                        for try await line in url.linesAutoDecompressing() {
                            if case .terminated = continuation.yield(line) {
                                throw CancellationError()
                            }
                            try Task.checkCancellation()
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

/// Serial holder for a Foundation `AsyncLineSequence` iterator inside a
/// `@Sendable` unfolding closure (one consumer at a time).
private final class AsyncLineIteratorBox: @unchecked Sendable {
    private var iterator: AsyncLineSequence<URL.AsyncBytes>.AsyncIterator
    init(_ iterator: AsyncLineSequence<URL.AsyncBytes>.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> String? { try await iterator.next() }
}
