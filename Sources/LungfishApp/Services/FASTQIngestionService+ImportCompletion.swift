// FASTQIngestionService+ImportCompletion.swift - How the row of a FASTQ import ends after a good run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension FASTQIngestionService {
    /// Ends the row of an import that published `bundleURL`. A static function so a test can end a row the way the run does.
    @MainActor
    static func completeImportRow(_ id: UUID, bundleURL: URL, center: OperationCenter = .shared) -> Bool {
        center.complete(id: id, detail: "Imported \(bundleURL.lastPathComponent)", bundleURLs: [bundleURL])
    }
}
