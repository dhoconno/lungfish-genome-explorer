// ProvenanceDirectoryManifest.swift - Files found under one directory root of a provenance record
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ProvenanceDirectoryManifest

public struct ProvenanceDirectoryManifest: Codable, Sendable, Equatable {
    public let rootPath: String
    public let files: [ProvenanceFileDescriptor]

    public init(rootPath: String, files: [ProvenanceFileDescriptor]) {
        self.rootPath = rootPath
        self.files = files
    }
}
