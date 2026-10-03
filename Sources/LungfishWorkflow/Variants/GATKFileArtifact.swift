// GATKFileArtifact.swift - An input or output file of a GATK pipeline step
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct GATKFileArtifact: Sendable, Equatable {
    public let url: URL
    public let format: FileFormat?
    public let role: FileRole

    public init(url: URL, format: FileFormat? = nil, role: FileRole) {
        self.url = url
        self.format = format
        self.role = role
    }

    public func fileRecord() -> FileRecord {
        ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
    }
}
