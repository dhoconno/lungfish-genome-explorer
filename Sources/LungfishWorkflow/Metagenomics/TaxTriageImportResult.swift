// TaxTriageImportResult.swift - Result metadata for an imported TaxTriage result directory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Result metadata for an imported TaxTriage result directory.
public struct TaxTriageImportResult: Sendable {
    public let resultDirectory: URL
    public let importedFileCount: Int
    public let reportEntryCount: Int

    public init(resultDirectory: URL, importedFileCount: Int, reportEntryCount: Int) {
        self.resultDirectory = resultDirectory
        self.importedFileCount = importedFileCount
        self.reportEntryCount = reportEntryCount
    }
}
