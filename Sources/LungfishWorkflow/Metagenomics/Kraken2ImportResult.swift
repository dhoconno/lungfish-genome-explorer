// Kraken2ImportResult.swift - Result metadata for an imported Kraken2 classification directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Result metadata for an imported Kraken2 classification directory.
public struct Kraken2ImportResult: Sendable {
    public let resultDirectory: URL
    public let totalReads: Int
    public let speciesCount: Int

    public init(resultDirectory: URL, totalReads: Int, speciesCount: Int) {
        self.resultDirectory = resultDirectory
        self.totalReads = totalReads
        self.speciesCount = speciesCount
    }
}
