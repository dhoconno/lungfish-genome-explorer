// FASTQOperationOutputImporter+ReadRoles.swift - The read roles of an operation output that mixes single reads with pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension AppFASTQOutputBundleWriter {

    /// The read roles to record beside a re-imported operation output that
    /// holds adjacent pairs and single reads, or nil for any other output.
    ///
    /// An operation on a source that holds pairs can write a file that mixes
    /// pairs with merged or orphan reads, a trim writing its pairs first and
    /// its single reads last. The import labels such an output single-end
    /// when its layout scan sees the mix, or interleaved when the single
    /// reads lie past the 100,000 records the scan reads, and recorded no
    /// roles either way. A later positional pair tool then paired the single
    /// reads (D10, Phase 1.5 lane A7). The whole stored file is counted
    /// (``FASTQMixedLayoutHint``), never the scan, and the roles are merge
    /// evidence to every later scan. Only an output whose source metadata
    /// records pairs or merged reads is counted, so single-end work costs no
    /// extra pass. An output that cannot be read fails the import.
    func outputReadRoles(of outputFASTQ: URL, sourceInputURL: URL?) throws -> ReadClassification? {
        guard let sourceInputURL else { return nil }
        let hints = FASTQReadLayoutClassifier.metadataHints(for: sourceInputURL)
        guard hints.claimsPairedContent || hints.hasMergedOrUnpairedReads else { return nil }
        let counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: outputFASTQ)
        return FASTQMixedLayoutHint.classification(
            pairs: counts.pairs,
            singles: counts.singles,
            singleRole: FASTQMixedLayoutHint.singleRole(of: sourceReadRoles(of: sourceInputURL)),
            filename: outputFASTQ.lastPathComponent
        )
    }

    /// The recorded read roles of a source bundle or file: its derived
    /// manifest's, else its primary FASTQ sidecar's.
    private func sourceReadRoles(of sourceInputURL: URL) -> ReadClassification? {
        let bundleURL = FASTQBundle.isBundleURL(sourceInputURL)
            ? sourceInputURL
            : SequenceInputResolver.enclosingFASTQBundleURL(for: sourceInputURL)
        if let bundleURL, let roles = FASTQBundle.loadDerivedManifest(in: bundleURL)?.readClassification {
            return roles
        }
        return FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL ?? sourceInputURL)
            .flatMap { FASTQMetadataStore.load(for: $0)?.readClassification }
    }
}
