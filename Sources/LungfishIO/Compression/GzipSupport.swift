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
    /// Streams from a gzip subprocess pipe in 1 MB chunks instead of loading
    /// the entire decompressed output into RAM. Memory usage is O(chunk size)
    /// regardless of file size.
    ///
    /// Handles both Unix (`\n`) and Windows (`\r\n`) line endings.
    ///
    /// - Returns: AsyncThrowingStream of String lines
    public func lines() -> AsyncThrowingStream<String, Error> {
        let fileURL = self.url
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try GzipInputStream.validateGzipHeader(at: fileURL)

                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                    process.arguments = ["-dc", fileURL.path]

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    let handle = stdoutPipe.fileHandleForReading
                    let chunkSize = 1_048_576 // 1 MB
                    var partial = Data() // Leftover bytes from previous chunk (incomplete line)

                    while true {
                        let chunk = handle.readData(ofLength: chunkSize)
                        if chunk.isEmpty { break }

                        partial.append(chunk)

                        // Find the last newline in the accumulated buffer.
                        // Everything before it can be split into complete lines.
                        // Everything after it is a partial line carried forward.
                        guard let lastNewline = partial.lastIndex(of: UInt8(ascii: "\n")) else {
                            // No newline yet — accumulate more data
                            continue
                        }

                        let completeRange = partial[partial.startIndex...lastNewline]
                        guard let text = String(data: Data(completeRange), encoding: .utf8) else {
                            throw GzipError.decompressionFailed("Invalid UTF-8 encoding in chunk")
                        }

                        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
                            continuation.yield(String(line))
                        }

                        // Keep the remainder after the last newline
                        let afterNewline = partial.index(after: lastNewline)
                        if afterNewline < partial.endIndex {
                            partial = Data(partial[afterNewline...])
                        } else {
                            partial = Data()
                        }
                    }

                    // Yield any remaining partial line
                    if !partial.isEmpty {
                        guard let text = String(data: partial, encoding: .utf8) else {
                            throw GzipError.decompressionFailed("Invalid UTF-8 encoding in final chunk")
                        }
                        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                        if !normalized.isEmpty {
                            continuation.yield(normalized)
                        }
                    }

                    process.waitUntilExit()

                    if process.terminationStatus != 0 {
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderrText = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw GzipError.decompressionFailed(
                            stderrText?.isEmpty == false ? stderrText! : "gzip exited with code \(process.terminationStatus)"
                        )
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Decompresses gzip data using the Compression framework.
    ///
    /// - Parameter data: Compressed gzip data
    /// - Returns: Decompressed data
    /// - Throws: `GzipError` if decompression fails
    private func decompress(_ data: Data) throws -> Data {
        // Skip gzip header (minimum 10 bytes for basic header)
        // Gzip format: magic(2) + method(1) + flags(1) + mtime(4) + xfl(1) + os(1)
        guard data.count >= 10 else {
            throw GzipError.decompressionFailed("Gzip header too short")
        }

        let flags = data[3]
        var headerSize = 10

        // FEXTRA flag (bit 2)
        if flags & 0x04 != 0 {
            guard data.count >= headerSize + 2 else {
                throw GzipError.decompressionFailed("Invalid FEXTRA field")
            }
            let xlen = Int(data[headerSize]) | (Int(data[headerSize + 1]) << 8)
            headerSize += 2 + xlen
        }

        // FNAME flag (bit 3) - null-terminated string
        if flags & 0x08 != 0 {
            while headerSize < data.count && data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1 // Skip null terminator
        }

        // FCOMMENT flag (bit 4) - null-terminated string
        if flags & 0x10 != 0 {
            while headerSize < data.count && data[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1 // Skip null terminator
        }

        // FHCRC flag (bit 1)
        if flags & 0x02 != 0 {
            headerSize += 2
        }

        guard headerSize < data.count - 8 else {
            throw GzipError.decompressionFailed("Gzip data too short after header")
        }

        // Remove 8-byte trailer (CRC32 + original size)
        let compressedBytes = data.subdata(in: headerSize..<(data.count - 8))

        // Use Compression framework to decompress
        return try decompressDeflate(compressedBytes)
    }

    /// Decompresses raw DEFLATE data.
    ///
    /// - Parameter data: DEFLATE compressed data
    /// - Returns: Decompressed data
    private func decompressDeflate(_ data: Data) throws -> Data {
        // Allocate output buffer (start with 4x input size, grow if needed)
        var outputData = Data(count: data.count * 4)
        var decompressedSize = 0

        try data.withUnsafeBytes { compressedBuffer in
            guard let compressedPointer = compressedBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw GzipError.decompressionFailed("Failed to access compressed data")
            }

            var success = false
            var bufferMultiplier = 4

            while !success && bufferMultiplier <= 256 {
                outputData = Data(count: data.count * bufferMultiplier)

                try outputData.withUnsafeMutableBytes { outputBuffer in
                    guard let outputPointer = outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        throw GzipError.decompressionFailed("Failed to allocate output buffer")
                    }

                    decompressedSize = compression_decode_buffer(
                        outputPointer,
                        outputBuffer.count,
                        compressedPointer,
                        compressedBuffer.count,
                        nil,
                        COMPRESSION_ZLIB
                    )

                    if decompressedSize == 0 || decompressedSize == outputBuffer.count {
                        // Buffer might be too small or decompression failed
                        bufferMultiplier *= 2
                    } else {
                        success = true
                    }
                }
            }

            if !success {
                throw GzipError.decompressionFailed("Decompression produced no output or buffer overflow")
            }
        }

        return outputData.prefix(decompressedSize)
    }

    /// Decompresses the entire file and returns the content as a string.
    ///
    /// - Returns: Decompressed file content
    /// - Throws: `GzipError` if decompression fails
    public func readAll() async throws -> String {
        let decompressedData = try decompressWithSystemGzip()

        guard let content = String(data: decompressedData, encoding: .utf8) else {
            throw GzipError.decompressionFailed("Invalid UTF-8 encoding")
        }

        return content
    }

    /// Validates that a file has a valid gzip header (magic bytes).
    ///
    /// Reads only the first 2 bytes — does not load the file into RAM.
    private static func validateGzipHeader(at url: URL) throws {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw GzipError.decompressionFailed("Failed to launch gzip: \(error.localizedDescription)")
        }

        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GzipError.decompressionFailed(
                stderrText?.isEmpty == false ? stderrText! : "gzip exited with code \(process.terminationStatus)"
            )
        }
        return output
    }
}

// MARK: - URL Extension for Gzip Detection

extension URL {
    /// Whether this URL points to a gzip-compressed file (based on extension).
    public var isGzipCompressed: Bool {
        pathExtension.lowercased() == "gz"
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
            // Use standard URL.lines for uncompressed files
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        for try await line in self.lines {
                            continuation.yield(line)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
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
            Task {
                do {
                    for url in urls {
                        for try await line in url.linesAutoDecompressing() {
                            continuation.yield(line)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
