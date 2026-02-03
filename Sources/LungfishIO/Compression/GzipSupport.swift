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
    /// - Returns: AsyncThrowingStream of String lines
    public func lines() -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Read the compressed data
                    let compressedData = try Data(contentsOf: url)

                    guard compressedData.count >= 2 else {
                        throw GzipError.emptyFile
                    }

                    // Verify gzip magic bytes
                    guard compressedData[0] == Self.gzipMagic[0],
                          compressedData[1] == Self.gzipMagic[1] else {
                        throw GzipError.invalidFormat
                    }

                    // Decompress
                    let decompressedData = try self.decompress(compressedData)

                    guard let content = String(data: decompressedData, encoding: .utf8) else {
                        throw GzipError.decompressionFailed("Invalid UTF-8 encoding")
                    }

                    // Yield lines
                    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(String(line))
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
        let compressedData = try Data(contentsOf: url)

        guard compressedData.count >= 2 else {
            throw GzipError.emptyFile
        }

        guard compressedData[0] == Self.gzipMagic[0],
              compressedData[1] == Self.gzipMagic[1] else {
            throw GzipError.invalidFormat
        }

        let decompressedData = try decompress(compressedData)

        guard let content = String(data: decompressedData, encoding: .utf8) else {
            throw GzipError.decompressionFailed("Invalid UTF-8 encoding")
        }

        return content
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
}
