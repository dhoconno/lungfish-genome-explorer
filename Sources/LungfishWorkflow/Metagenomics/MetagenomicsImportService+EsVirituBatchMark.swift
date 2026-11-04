// MetagenomicsImportService+EsVirituBatchMark.swift - The batch mark of an imported EsViritu folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension MetagenomicsImportService {
    /// Gives an imported EsViritu folder the importer's own batch mark unless the folder holds a batch.
    ///
    /// The copy puts the source's own metadata over the importer's. A batch mark is right only for a folder that holds a
    /// batch, which is a batch manifest or a sample folder with a result in it, and the sidebar lists exactly those. A flat
    /// folder that carries the mark (hand built, or a batch whose sample folders are gone) is skipped there as an empty
    /// batch, so the person cannot reach what they imported. For that folder the importer's own mark, one result and no
    /// batch, wins again (row IMPORT-ESVIRITU-FLAT-BATCH-HIDDEN).
    static func keepBatchMarkOnlyForABatch(in directory: URL) {
        guard !holdsEsVirituBatch(directory) else { return }
        let metadata = AnalysesFolder.AnalysisMetadata(tool: MetagenomicsImportKind.esviritu.toolIdentifier, isBatch: false)
        try? AnalysesFolder.writeAnalysisMetadata(metadata, to: directory)
    }

    /// Whether the folder holds a batch manifest or a sample folder with an EsViritu result, as the sidebar requires.
    private static func holdsEsVirituBatch(_ directory: URL) -> Bool {
        if MetagenomicsBatchResultStore.loadEsViritu(from: directory) != nil { return true }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { child in
            (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && EsVirituResult.exists(in: child)
        }
    }
}
