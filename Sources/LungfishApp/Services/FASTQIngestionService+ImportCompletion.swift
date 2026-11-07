// FASTQIngestionService+ImportCompletion.swift - How the row of a FASTQ import ends after a good run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit

extension FASTQIngestionService {
    /// Ends the row of an import that published `bundleURL`. A static function so a test can end a row the way the run does.
    /// A warning the run logged on the row is named in its detail line, since only the Log held it (IMPORT-WARN-SUBTITLE).
    @MainActor
    static func completeImportRow(_ id: UUID, bundleURL: URL, center: OperationCenter = .shared) -> Bool {
        let causes = center.items.first { $0.id == id }.map(ImportWarningWords.causes(in:)) ?? []
        let detail = ImportWarningWords.detail("Imported \(bundleURL.lastPathComponent)", causes: causes)
        return center.complete(id: id, detail: detail, bundleURLs: [bundleURL])
    }
}
