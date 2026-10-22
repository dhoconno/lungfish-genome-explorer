// RecipeDatabaseRecord.swift - The database file a recipe step read, by its identity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One database file a recipe step read, such as the Deacon index of a host scrub. It names the file by its lock
/// id and version, its bytes (SHA-256 and size) and the index header it holds, so a plan built elsewhere can prove
/// it read the same file (CHTC lane L5-RECORDS M2).
public struct RecipeDatabaseRecord: Codable, Sendable, Equatable {
    /// The database's lock id, such as `deacon-panhuman`.
    public let id: String
    /// The lock version of the database, such as `panhuman-1`.
    public let version: String
    /// The name of the file the step read.
    public let fileName: String
    /// The index format the file's header gives, or the lock's when the file has no header this build reads.
    public let indexFormat: Int?
    /// The k-mer length the index header gives, when it has one.
    public let kmerLength: Int?
    /// The minimizer window the index header gives, when it has one.
    public let windowSize: Int?
    /// SHA-256 of the file's bytes.
    public let sha256: String
    /// The file's size in bytes.
    public let sizeBytes: Int64
    /// The path the step read.
    public let path: String
    /// Whether the lock pins this file's SHA-256 and size. When it does, the step ran only after the file matched.
    public let lockPinned: Bool
    /// SHA-256 of the file a local install built the index from, from the install record, when the index was built
    /// on this host rather than fetched.
    public let buildSourceSHA256: String?
    /// The size of that source file, from the install record.
    public let buildSourceSizeBytes: Int64?
    /// The version of the tool that built the index, from the install record.
    public let buildToolVersion: String?

    public init(
        id: String,
        version: String,
        fileName: String,
        indexFormat: Int?,
        kmerLength: Int? = nil,
        windowSize: Int? = nil,
        sha256: String,
        sizeBytes: Int64,
        path: String,
        lockPinned: Bool,
        buildSourceSHA256: String? = nil,
        buildSourceSizeBytes: Int64? = nil,
        buildToolVersion: String? = nil
    ) {
        self.id = id
        self.version = version
        self.fileName = fileName
        self.indexFormat = indexFormat
        self.kmerLength = kmerLength
        self.windowSize = windowSize
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.path = path
        self.lockPinned = lockPinned
        self.buildSourceSHA256 = buildSourceSHA256
        self.buildSourceSizeBytes = buildSourceSizeBytes
        self.buildToolVersion = buildToolVersion
    }
}
