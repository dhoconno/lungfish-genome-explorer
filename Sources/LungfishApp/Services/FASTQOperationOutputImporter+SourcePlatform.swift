// FASTQOperationOutputImporter+SourcePlatform.swift - The platform an operation's output takes from its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension AppFASTQOutputBundleWriter {

    /// Records in `metadata`, the sidecar of a re-imported operation output, the sequencing platform and the
    /// assembly read type the operation's source records, when the output records neither. The reads of the output
    /// are the source's reads (a subsample, a trim, a filter), so their platform is the source's. Without the
    /// record the Demultiplex dialog started on TruSeq Single Index Set A for ONT reads, and an ONT subset of reads
    /// 600 bases or shorter mapped and assembled with Illumina settings (row DEMUX-C, BIO ruling S2).
    ///
    /// The source is resolved as the importer resolves it for the pairing it records, a bundle, a file in a bundle
    /// or a plain file. A source a build up to 12859 made, or a virtual derivative, records nothing of its own, so
    /// the record is the nearest one in its lineage (``FASTQMetadataStore/platformRecord(for:)``). An output that
    /// already records either field keeps it, and a source with no record anywhere leaves the output's empty.
    func recordSourcePlatform(of sourceInputURL: URL?, in metadata: inout PersistedFASTQMetadata) {
        guard metadata.sequencingPlatform == nil, metadata.assemblyReadType == nil,
              let sourceFASTQ = primaryFASTQ(ofSource: sourceInputURL),
              let record = FASTQMetadataStore.platformRecord(for: sourceFASTQ) else { return }
        metadata.sequencingPlatform = record.sequencingPlatform
        metadata.assemblyReadType = record.assemblyReadType
    }

    /// The primary FASTQ of the operation's source, the file itself or the primary file of its bundle.
    private func primaryFASTQ(ofSource sourceInputURL: URL?) -> URL? {
        guard let sourceInputURL else { return nil }
        if FASTQBundle.isFASTQFileURL(sourceInputURL) { return sourceInputURL }
        let bundleURL = FASTQBundle.isBundleURL(sourceInputURL)
            ? sourceInputURL
            : SequenceInputResolver.enclosingFASTQBundleURL(for: sourceInputURL)
        return bundleURL.flatMap { FASTQBundle.resolvePrimaryFASTQURL(for: $0) }
    }
}
