// SidebarProjectScanner+BlastSearch.swift - A BLAST search folder stays out of the sidebar until its record exists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension SidebarProjectScanner {
    /// Whether `url` is the folder of a BLAST search that has no result record yet (BLAST-FAILED-LEFTOVERS).
    ///
    /// `blast submit` writes `blast-search.json` first and `blast-result.json` only when a result exists. A search that
    /// waits at NCBI for hours, or that ended with nothing to show, left a folder of `query.fasta` and a provenance
    /// file, which read as a result with nothing in it. The folder shows once its record exists. The Operations row and
    /// the viewer's pane carry the search until then. A folder with no search file (an older run) is listed as before.
    /// The scanner lives in a file at its size baseline, so the check lives here and `isIncompleteOutput` calls it.
    static func isBlastSearchWithoutRecord(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.appendingPathComponent(BlastSearchFile.fileName).path)
            && !fileManager.fileExists(atPath: url.appendingPathComponent(BlastSubmissionRecord.recordFileName).path)
    }
}
