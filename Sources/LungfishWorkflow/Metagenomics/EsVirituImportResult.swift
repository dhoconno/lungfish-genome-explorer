// EsVirituImportResult.swift - Result metadata for an imported EsViritu result directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Result metadata for an imported EsViritu result directory.
public struct EsVirituImportResult: Sendable {
    public let resultDirectory: URL
    public let importedFileCount: Int
    public let virusCount: Int

    public init(resultDirectory: URL, importedFileCount: Int, virusCount: Int) {
        self.resultDirectory = resultDirectory
        self.importedFileCount = importedFileCount
        self.virusCount = virusCount
    }
}
