// FASTQOperationOutputImporter+ReadRoles.swift - The read roles of an operation output that mixes single reads with pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let readRolesLogger = Logger(subsystem: LogSubsystem.app, category: "FASTQOperationOutputImporter")

extension AppFASTQOutputBundleWriter {

    /// Records in `metadata`, the sidecar of a re-imported operation output,
    /// the read roles ``outputReadRoles(of:sourceInputURL:)`` counts. A count
    /// of only pairs also records the pairing as `interleaved`, in the sidecar
    /// and so in the derived manifest written from it.
    ///
    /// `outputPairingMode(for:sourceInputURL:)` reads the source's merge as
    /// proof of single reads, so it labels a merge bundle's output of only
    /// pairs single-end. The Inspector then showed Single End for a file of
    /// pairs, and a later operation on it was not counted, because the label
    /// claimed no pairs and the count had cleared the merge hint (Phase 1.5
    /// lane F8, re-review finding F6-S1).
    func recordReadRolesAndPairing(
        of outputFASTQ: URL,
        sourceInputURL: URL?,
        in metadata: inout PersistedFASTQMetadata
    ) {
        guard let roles = outputReadRoles(of: outputFASTQ, sourceInputURL: sourceInputURL) else { return }
        metadata.readClassification = roles
        guard roles.mergedReadCount == 0, roles.unpairedReadCount == 0 else { return }
        if metadata.ingestion?.pairingMode != .interleaved {
            readRolesLogger.info(
                "importFASTQOutput: \(outputFASTQ.lastPathComponent, privacy: .public) holds only pairs by its count, so it is recorded as interleaved"
            )
        }
        metadata.ingestion?.pairingMode = .interleaved
    }

    /// The read roles to record beside a re-imported operation output that
    /// holds adjacent pairs and single reads, or that holds only pairs and
    /// comes from a source with merge evidence, or nil for any other output.
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
    /// extra pass. An output whose records cannot be read is logged at error
    /// level and records no roles, the state before this lane.
    ///
    /// An operation on a merge bundle can also keep only its unmerged pairs.
    /// That output inherits the merge in its lineage, which the layout scan
    /// reads as proof of single reads, and with no counts recorded the resolver
    /// planned it as mixed. Its pairs are recorded with no single role
    /// (``FASTQMixedLayoutHint/pairsOnlyClassification(pairs:singles:filename:)``),
    /// so the resolver plans it as the pairs it is. A pairs-only output of a
    /// source with no merge evidence records nothing, as before (Phase 1.5
    /// lane F6, re-review SHOULD-FIX 2).
    ///
    /// The merge evidence includes a merge in the source's lineage, read from
    /// its manifest, because the output inherits that merge whatever the
    /// source's own counts say. A source's count of only pairs clears the
    /// merge from its layout hints, so a decision from the hints alone left
    /// every later generation without counts (Phase 1.5 lane F8, re-review
    /// finding F6-S1).
    func outputReadRoles(of outputFASTQ: URL, sourceInputURL: URL?) -> ReadClassification? {
        guard let sourceInputURL else { return nil }
        let hints = FASTQReadLayoutClassifier.metadataHints(for: sourceInputURL)
        let sourceRecordsMerge = hints.hasMergedOrUnpairedReads || lineageRecordsMerge(of: sourceInputURL)
        guard hints.claimsPairedContent || sourceRecordsMerge else { return nil }
        let counts: (pairs: Int, singles: Int)
        do {
            counts = try FASTQMixedLayoutHint.countPairsAndSingles(in: outputFASTQ)
        } catch {
            readRolesLogger.error(
                "importFASTQOutput: cannot count the pairs and single reads of \(outputFASTQ.lastPathComponent, privacy: .public), so no read roles are recorded: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
        if let roles = FASTQMixedLayoutHint.classification(
            pairs: counts.pairs,
            singles: counts.singles,
            singleRole: FASTQMixedLayoutHint.singleRole(of: sourceReadRoles(of: sourceInputURL)),
            filename: outputFASTQ.lastPathComponent
        ) {
            return roles
        }
        guard sourceRecordsMerge else { return nil }
        return FASTQMixedLayoutHint.pairsOnlyClassification(
            pairs: counts.pairs,
            singles: counts.singles,
            filename: outputFASTQ.lastPathComponent
        )
    }

    /// Whether the derived manifest of a source bundle, or of the bundle that
    /// holds a source file, records a paired-end merge in its lineage or as
    /// its own operation, the rule ``FASTQReadLayoutClassifier/metadataHints(for:)``
    /// applies.
    private func lineageRecordsMerge(of sourceInputURL: URL) -> Bool {
        guard let manifest = sourceBundleURL(of: sourceInputURL).flatMap(FASTQBundle.loadDerivedManifest(in:)) else {
            return false
        }
        return manifest.operation.kind == .pairedEndMerge
            || manifest.lineage.contains { $0.kind == .pairedEndMerge }
    }

    /// The source bundle itself, or the bundle that holds a source file.
    private func sourceBundleURL(of sourceInputURL: URL) -> URL? {
        FASTQBundle.isBundleURL(sourceInputURL)
            ? sourceInputURL
            : SequenceInputResolver.enclosingFASTQBundleURL(for: sourceInputURL)
    }

    /// The recorded read roles of a source bundle or file: its derived
    /// manifest's, else its primary FASTQ sidecar's.
    private func sourceReadRoles(of sourceInputURL: URL) -> ReadClassification? {
        let bundleURL = sourceBundleURL(of: sourceInputURL)
        if let bundleURL, let roles = FASTQBundle.loadDerivedManifest(in: bundleURL)?.readClassification {
            return roles
        }
        return FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL ?? sourceInputURL)
            .flatMap { FASTQMetadataStore.load(for: $0)?.readClassification }
    }
}
