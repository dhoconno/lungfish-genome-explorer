// FileRecord.swift - Metadata for an input or output file in a provenance record
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - FileRecord

/// Metadata for an input or output file in a provenance record.
public struct FileRecord: Codable, Sendable, Equatable {
    /// Original file path (relative to project root when possible).
    public let path: String

    /// SHA-256 checksum of the file contents.
    public let sha256: String?

    /// File size in bytes.
    public let sizeBytes: UInt64?

    /// File format identifier.
    public let format: FileFormat?

    /// Role of this file in the step.
    public let role: FileRole

    public init(
        path: String,
        sha256: String? = nil,
        sizeBytes: UInt64? = nil,
        format: FileFormat? = nil,
        role: FileRole = .input
    ) {
        self.path = path
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.format = format
        self.role = role
    }

    /// The filename component of the path.
    public var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

extension FileRecord {
    public init(provenanceFile: ProvenanceFileDescriptor) {
        self.init(
            path: provenanceFile.path,
            sha256: provenanceFile.checksumSHA256,
            sizeBytes: provenanceFile.fileSize,
            format: provenanceFile.format,
            role: provenanceFile.role
        )
    }
}
