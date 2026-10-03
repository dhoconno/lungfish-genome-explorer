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
    /// pairs with merged or orphan reads, a trim of a mixed file writing its
    /// pairs first and its single reads last. The import labels such an output
    /// single-end, the contract default, and recorded no roles, so with more
    /// pair records than the 100,000-record layout scan the bundle later read
    /// as strictly interleaved and a positional pair tool paired its single
    /// reads (D10, Phase 1.5 lane A7). The roles are counted in the imported
    /// file, so they describe the records as stored, and they are merge
    /// evidence to the scan (``FASTQMixedLayoutHint``). Only an output whose
    /// source metadata records pairs or merged reads is counted, so single-end
    /// work costs no extra pass.
    func outputReadRoles(of outputFASTQ: URL, sourceInputURL: URL?) -> ReadClassification? {
        guard let sourceInputURL else { return nil }
        let hints = FASTQReadLayoutClassifier.metadataHints(for: sourceInputURL)
        guard hints.claimsPairedContent || hints.hasMergedOrUnpairedReads,
              FASTQInputLayoutResolver.resolve(fastqURL: outputFASTQ, metadataFrom: sourceInputURL).layout
                == .mixedMergedAndPairs,
              let counts = try? FASTQMixedLayoutHint.countPairsAndSingles(in: outputFASTQ) else {
            return nil
        }
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
