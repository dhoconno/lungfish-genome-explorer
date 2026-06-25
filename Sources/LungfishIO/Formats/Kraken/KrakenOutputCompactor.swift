// KrakenOutputCompactor.swift - Retention helpers for Kraken2 per-read output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Errors raised while compacting Kraken2 per-read output.
public enum KrakenOutputCompactorError: Error, LocalizedError, Sendable {
    case gzipFailed(exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .gzipFailed(let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "gzip failed with exit code \(exitCode)"
            }
            return "gzip failed with exit code \(exitCode): \(detail)"
        }
    }
}

/// Utilities for retaining Kraken2 per-read output in a compact, queryable form.
public enum KrakenOutputCompactor {
    /// Builds a classified-read SQLite index, writes a gzip copy of the raw
    /// Kraken2 output, and optionally removes the raw input after both retained
    /// artifacts exist.
    ///
    /// - Parameters:
    ///   - rawURL: Raw `classification.kraken` file.
    ///   - compressedURL: Destination gzip URL. Defaults to `rawURL + ".gz"`.
    ///   - includeUnclassifiedInIndex: Whether the SQLite index should include
    ///     unclassified rows. New retained Kraken2 outputs normally use
    ///     classified-only indexes and rely on the gzip file for unclassified
    ///     extraction fallback.
    ///   - removeRawOnSuccess: Remove `rawURL` only after index and gzip succeed.
    /// - Returns: The compressed output URL.
    public static func compact(
        rawURL: URL,
        compressedURL explicitCompressedURL: URL? = nil,
        includeUnclassifiedInIndex: Bool = false,
        removeRawOnSuccess: Bool = true
    ) throws -> URL {
        let fm = FileManager.default
        let compressedURL = explicitCompressedURL ?? rawURL.appendingPathExtension("gz")
        let indexURL = KrakenIndexDatabase.indexURL(for: compressedURL)

        do {
            try? fm.removeItem(at: compressedURL)
            removeSQLiteDatabase(at: indexURL)

            try KrakenIndexDatabase.build(
                from: rawURL,
                to: indexURL,
                includeUnclassified: includeUnclassifiedInIndex
            )
            try gzipCopy(source: rawURL, destination: compressedURL)

            if removeRawOnSuccess {
                try fm.removeItem(at: rawURL)
            }

            return compressedURL
        } catch {
            try? fm.removeItem(at: compressedURL)
            removeSQLiteDatabase(at: indexURL)
            throw error
        }
    }

    /// Streams `source` through `/usr/bin/gzip -c` into `destination`.
    public static func gzipCopy(source: URL, destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        fm.createFile(atPath: destination.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destination)
        defer { outputHandle.closeFile() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = outputHandle
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw KrakenOutputCompactorError.gzipFailed(
                exitCode: process.terminationStatus,
                stderr: stderrText
            )
        }
    }

    public static func removeSQLiteDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}
