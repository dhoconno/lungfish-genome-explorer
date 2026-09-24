// FileDigest.swift - Shared streaming SHA-256 helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Shared SHA-256 hashing for files and in-memory data.
///
/// SIMP-10 (2026-09-23 best-practices audit): the codebase had 49 separate
/// `sha256`/`computeSHA256` helpers spread across 5 modules. Some read the
/// whole file into memory (unbounded memory use on large files); others
/// streamed with differing, undocumented chunk sizes. `FileDigest` is the
/// one streaming, cancellable implementation new call sites should use
/// (promoted from the former `LungfishWorkflow.ProvenanceFileHasher`, which
/// is now a thin wrapper over this type to avoid breaking its existing
/// call sites and provenance-manifest API).
public enum FileDigest {
    /// Bytes read per chunk while streaming a file's contents into the
    /// hasher. Chosen to match the prior `ProvenanceFileHasher` default so
    /// promoting callers to `FileDigest` does not change hashing behavior
    /// or performance characteristics.
    public static let defaultChunkSize = 1_048_576

    /// Computes the SHA-256 digest of the file at `url`, streaming it in
    /// `chunkSize`-byte chunks rather than loading the whole file into
    /// memory.
    ///
    /// - Parameters:
    ///   - url: The file to hash.
    ///   - chunkSize: Bytes read per chunk. Defaults to `defaultChunkSize`.
    ///   - cancellationCheck: Invoked before each chunk read; throw from
    ///     this closure to abort hashing early (e.g. on `Task` cancellation).
    /// - Returns: The lowercase hex-encoded digest.
    public static func sha256(
        of url: URL,
        chunkSize: Int = defaultChunkSize,
        cancellationCheck: () throws -> Void = {}
    ) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            try cancellationCheck()
            let chunk = fileHandle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        return hexString(from: hasher.finalize())
    }

    /// Computes the SHA-256 digest of in-memory `data`.
    public static func sha256Hex(of data: Data) -> String {
        hexString(from: SHA256.hash(data: data))
    }

    private static func hexString(from digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    /// Convenience accessor for `FileDigest.sha256Hex(of:)`.
    public var sha256Hex: String { FileDigest.sha256Hex(of: self) }
}
