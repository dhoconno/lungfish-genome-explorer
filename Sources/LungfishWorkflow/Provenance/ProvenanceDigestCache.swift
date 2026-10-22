// ProvenanceDigestCache.swift - One SHA-256 per file per import command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// What a file was when it was hashed: the resolved path, the device and inode, the size and the modification time to
/// the nanosecond. A file that is written to or replaced afterwards no longer matches.
public struct ProvenanceFileStamp: Hashable, Sendable {
    public let resolvedPath: String
    public let device: UInt64
    public let inode: UInt64
    public let size: UInt64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    /// The stamp of the file at `url`, or nil when it cannot be read with `stat`.
    public init?(url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        resolvedPath = url.resolvingSymlinksInPath().path
        device = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(info.st_ino)
        size = UInt64(truncatingIfNeeded: info.st_size)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
    }
}

/// The SHA-256 of each file one import command described in its record, taken once.
///
/// L6-O10 found a 30 GB input read 8 times and the staged payload 6 times between the statistics step and the
/// published bundle, 11 minutes of a 92 minute import, because every record site hashed the file again. A command
/// binds one cache with ``scoped(_:operation:)``, and ``ProvenanceRecorder/fileRecord(url:format:role:)`` and
/// ``ProvenanceFileDescriptor/file(url:format:role:originPath:sourceProvenancePath:cancellationCheck:)`` take their
/// digests from it, so a file the command described twice is read once. Code that checks a file against a digest
/// on purpose, such as a copy verification, keeps reading the disk through ``ProvenanceFileHasher``.
///
/// A digest is kept with the ``ProvenanceFileStamp`` the file had when it was read. A file whose path, size, inode or
/// modification time differs from the stamp is read again, and a file that changed while it was being read is not
/// kept. A file renamed inside the command is a new path and is read again. Two callers that ask for the same new
/// file at the same moment may both read it. The cache never holds a digest of other bytes.
public final class ProvenanceDigestCache: Sendable {
    /// Reads a file and returns its lowercase hex SHA-256. The cancellation check runs between chunks.
    package typealias DigestReader = @Sendable (URL, () throws -> Void) throws -> String

    private struct Entry: Sendable {
        let stamp: ProvenanceFileStamp
        let sha256: String
    }

    private struct State: Sendable {
        var byPath: [String: Entry] = [:]
        var reads = 0
        var readsByPath: [String: Int] = [:]
    }

    private let reader: DigestReader
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The cache of the import command now running, nil outside one.
    @TaskLocal public static var current: ProvenanceDigestCache? = nil

    public init() {
        self.reader = { url, cancellationCheck in
            try ProvenanceFileHasher.sha256(of: url, cancellationCheck: cancellationCheck)
        }
    }

    /// A cache that reads through `reader`, so a test can count the reads or stand in for the disk.
    package init(reader: @escaping DigestReader) {
        self.reader = reader
    }

    /// How many files this cache has read, whatever their path.
    public var readCount: Int { state.withLock { $0.reads } }

    /// How many times this cache has read the file at `url`.
    public func readCount(of url: URL) -> Int {
        state.withLock { $0.readsByPath[url.resolvingSymlinksInPath().path, default: 0] }
    }

    /// The SHA-256 of the file at `url`, read now or taken from the read this command already made.
    public func sha256(of url: URL, cancellationCheck: () throws -> Void = {}) throws -> String {
        guard let stamp = ProvenanceFileStamp(url: url) else {
            let sha256 = try reader(url, cancellationCheck)
            state.withLock { $0.reads += 1 }
            return sha256
        }
        let cached: String? = state.withLock { state in
            if let entry = state.byPath[stamp.resolvedPath], entry.stamp == stamp { return entry.sha256 }
            return nil
        }
        if let cached { return cached }

        let sha256 = try reader(url, cancellationCheck)
        let unchanged = ProvenanceFileStamp(url: url) == stamp // a file written to during the read is not kept
        state.withLock { state in
            state.reads += 1
            state.readsByPath[stamp.resolvedPath, default: 0] += 1
            if unchanged { state.byPath[stamp.resolvedPath] = Entry(stamp: stamp, sha256: sha256) }
        }
        return sha256
    }

    /// The SHA-256 of the file at `url` for a record: from the cache of the command now running when there is one,
    /// else read from the disk.
    public static func digest(of url: URL, cancellationCheck: () throws -> Void = {}) throws -> String {
        if let cache = current { return try cache.sha256(of: url, cancellationCheck: cancellationCheck) }
        return try ProvenanceFileHasher.sha256(of: url, cancellationCheck: cancellationCheck)
    }

    /// Runs `operation` with a cache bound for the whole command: `cache` when given, the cache a caller already
    /// bound otherwise, else a new one.
    public static func scoped<T>(
        _ cache: ProvenanceDigestCache? = nil,
        operation: () async throws -> T
    ) async rethrows -> T {
        let bound = cache ?? current ?? ProvenanceDigestCache()
        return try await $current.withValue(bound, operation: operation)
    }
}
