// KrakenOutputCompactor.swift - Retention helpers for Kraken2 per-read output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

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
    /// The files one compaction wrote.
    public struct Compaction: Sendable, Equatable {
        /// The gzip copy of the raw per-read output.
        public let compressedURL: URL
        /// The classified-read SQLite index beside the gzip copy.
        public let indexURL: URL

        /// Every file the compaction wrote, the gzip copy first. A record step that names the copy or the index
        /// names both, since the compaction made them together.
        public var writtenFiles: [URL] { [compressedURL, indexURL] }
    }

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
    /// - Returns: The gzip copy and the index, the two files the compaction wrote.
    public static func compact(
        rawURL: URL,
        compressedURL explicitCompressedURL: URL? = nil,
        includeUnclassifiedInIndex: Bool = false,
        removeRawOnSuccess: Bool = true
    ) throws -> Compaction {
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

            return Compaction(compressedURL: compressedURL, indexURL: indexURL)
        } catch {
            try? fm.removeItem(at: compressedURL)
            removeSQLiteDatabase(at: indexURL)
            throw error
        }
    }

    /// Streams `source` through `/usr/bin/gzip -c` and publishes the result as `destination` through
    /// ``DurableGzip``, so the name holds a whole copy or what it held before, never a cut one.
    public static func gzipCopy(source: URL, destination: URL) throws {
        do {
            try DurableGzip.compress(source: source, to: destination)
        } catch DurableGzipError.gzipFailed(let exitCode, let stderr) {
            throw KrakenOutputCompactorError.gzipFailed(exitCode: exitCode, stderr: stderr)
        }
    }

    public static func removeSQLiteDatabase(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? fm.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }
}
