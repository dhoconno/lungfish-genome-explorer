// NvdImportResult.swift - Result metadata for an imported NVD result directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Result metadata for an imported NVD result directory.
public struct NvdImportResult: Sendable {
    public let resultDirectory: URL
    public let sampleCount: Int
    public let hitCount: Int
    public let contigCount: Int
    public let copiedBAMCount: Int
    public let copiedBAMIndexCount: Int
    public let copiedFASTACount: Int
    public let markdupBAMCount: Int
    public let uniqueReadRowsUpdated: Int

    public init(
        resultDirectory: URL,
        sampleCount: Int,
        hitCount: Int,
        contigCount: Int,
        copiedBAMCount: Int,
        copiedBAMIndexCount: Int,
        copiedFASTACount: Int,
        markdupBAMCount: Int,
        uniqueReadRowsUpdated: Int
    ) {
        self.resultDirectory = resultDirectory
        self.sampleCount = sampleCount
        self.hitCount = hitCount
        self.contigCount = contigCount
        self.copiedBAMCount = copiedBAMCount
        self.copiedBAMIndexCount = copiedBAMIndexCount
        self.copiedFASTACount = copiedFASTACount
        self.markdupBAMCount = markdupBAMCount
        self.uniqueReadRowsUpdated = uniqueReadRowsUpdated
    }
}
