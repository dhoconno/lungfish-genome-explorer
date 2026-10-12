// FASTQBundleMergeService+ReadRoles.swift - What the read-set resolver needs to plan a combined FASTQ bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

extension FASTQBundleMergeService {

    /// Whether the read-set resolver reads `fastqURL`, the one file of a
    /// root, as single reads only. Its sidecar records no read roles, and it
    /// records a long-read platform, which is never paired, or the layout of
    /// its metadata and of a bounded scan of its records holds no mate.
    ///
    /// Only such roots are linked as chunks of a combined bundle, because the
    /// resolver reads every chunk as single reads. A root recorded single-end
    /// whose file holds pairs, which the resolver plans as pairs on its own,
    /// became such a chunk, so a combined bundle ran its pairs as single
    /// reads (Phase 2.1 lane L3).
    static func readSetResolverReadsOnlySingleReads(in fastqURL: URL) -> Bool {
        let metadata = FASTQMetadataStore.load(for: fastqURL)
        guard metadata?.readClassification == nil else { return false }
        if let platform = metadata?.sequencingPlatform, platform == .oxfordNanopore || platform == .pacbio {
            return true
        }
        return FASTQInputLayoutResolver.resolve(inputURLs: [fastqURL]).layout == .singleEnd
    }

    /// Saves `metadata` beside `outputFASTQ`, the one file of a combined
    /// bundle that joins `inputFiles`, the files of each of `sourceBundleURLs`
    /// in order, with what the read-set resolver needs to plan it.
    ///
    /// The joined file is counted by kind
    /// (``FASTQMixedLayoutHint/readCounts(joining:)``). A file of pairs and
    /// single reads records those counts by role, in the form a merge recipe
    /// writes, and every file records the pairing its counts give. A combined
    /// bundle used to record only the inputs' shared pairing and no count, and
    /// it has no lineage, so a bounded scan that saw only pairs planned the
    /// single reads behind them as pairs (re-review F8-N2). Long reads are
    /// never paired, so they are not counted.
    static func save(
        _ metadata: PersistedFASTQMetadata,
        recordingTheRolesOf inputFiles: [[URL]],
        from sourceBundleURLs: [URL],
        for outputFASTQ: URL
    ) throws {
        var metadata = metadata
        let platform = metadata.sequencingPlatform
        if platform != .oxfordNanopore, platform != .pacbio {
            let sources = zip(inputFiles, sourceBundleURLs).map { files, bundleURL in
                FASTQMixedLayoutHint.JoinedSource(files: files, recordedRoles: recordedRoles(of: files, in: bundleURL))
            }
            let counts = try FASTQMixedLayoutHint.readCounts(joining: sources)
            metadata.readClassification = counts.classification(filename: outputFASTQ.lastPathComponent)
            metadata.ingestion?.pairingMode = counts.pairingMode
        }
        FASTQMetadataStore.save(metadata, for: outputFASTQ)
    }

    /// The roles a combined input records for its reads. They are those
    /// beside the one file it was resolved to (a root's own file, or a
    /// materialized mixed derivative's hint), else those its bundle records.
    private static func recordedRoles(of files: [URL], in bundleURL: URL) -> ReadClassification? {
        if files.count == 1, let roles = FASTQMetadataStore.load(for: files[0])?.readClassification {
            return roles
        }
        return FASTQMixedLayoutHint.recordedRoles(of: bundleURL)
    }
}
