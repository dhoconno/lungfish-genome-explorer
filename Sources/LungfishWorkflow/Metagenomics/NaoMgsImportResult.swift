// NaoMgsImportResult.swift - Result metadata for an imported NAO-MGS result directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Result metadata for an imported NAO-MGS result directory.
public struct NaoMgsImportResult: Sendable {
    public let resultDirectory: URL
    public let sampleName: String
    public let totalHitReads: Int
    public let taxonCount: Int
    public let fetchedReferenceCount: Int
    public let createdBAM: Bool

    public init(
        resultDirectory: URL,
        sampleName: String,
        totalHitReads: Int,
        taxonCount: Int,
        fetchedReferenceCount: Int,
        createdBAM: Bool
    ) {
        self.resultDirectory = resultDirectory
        self.sampleName = sampleName
        self.totalHitReads = totalHitReads
        self.taxonCount = taxonCount
        self.fetchedReferenceCount = fetchedReferenceCount
        self.createdBAM = createdBAM
    }
}
