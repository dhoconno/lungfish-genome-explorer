// Kraken2SampleResultDirectory.swift - The result folder of a Kraken 2 sample in a database-backed display
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane LEAF. The taxonomy view's collection Extract and the viewer's BLAST callback find a sample's
// folder the same way, so the helper sits in the leaf that holds the view and the App imports.

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

/// The result folder of the Kraken 2 sample `sampleId` in a database-backed display: the batch
/// manifest's sample folder, or `resultURL` itself for a single-sample result when
/// `fallsBackToResultFolder` holds. A caller that must act on one named sample passes false for a
/// batch of several, since the batch folder's own sidecar belongs to none of them. Only checks that
/// the folder holds a classification sidecar.
public func kraken2SampleResultDirectory(
    resultURL: URL,
    sampleId: String?,
    fallsBackToResultFolder: Bool = true
) -> URL? {
    func hasSidecar(_ directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(ClassificationResult.sidecarFilename).path
        )
    }
    if let manifest = MetagenomicsBatchResultStore.loadClassification(from: resultURL),
       let sampleId,
       let sampleRecord = manifest.samples.first(where: { $0.sampleId == sampleId }) {
        let directory = resultURL.appendingPathComponent(sampleRecord.resultDirectory)
        if hasSidecar(directory) { return directory }
    }
    return fallsBackToResultFolder && hasSidecar(resultURL) ? resultURL : nil
}
