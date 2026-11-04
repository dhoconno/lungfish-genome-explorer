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
    /// What the import says of the run's own provenance record when it cannot or should not claim the run whole
    /// (UX-IMPORT-REHYDRATE items 10 and 11). Nil when the record was carried and matches what the run left.
    public let sourceRunNote: String?

    public init(resultDirectory: URL, importedFileCount: Int, reportEntryCount: Int, sourceRunNote: String? = nil) {
        self.resultDirectory = resultDirectory
        self.importedFileCount = importedFileCount
        self.reportEntryCount = reportEntryCount
        self.sourceRunNote = sourceRunNote
    }
}
