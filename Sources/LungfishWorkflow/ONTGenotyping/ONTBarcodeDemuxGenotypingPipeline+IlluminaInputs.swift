// ONTBarcodeDemuxGenotypingPipeline+IlluminaInputs.swift - One Illumina sample's reads and staged file names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved unchanged out of ONTBarcodeDemuxGenotypingPipeline.swift, which is at its length baseline.

import Foundation

extension ONTBarcodeDemuxGenotypingPipeline {
    struct IlluminaSampleInput {
        let sampleID: String
        let sourceURL: URL
        /// The sample's reads as imported.
        let fastqURL: URL
        /// The reads actually handed to minimap2. Equals `fastqURL` unless the
        /// input held unmerged pairs, in which case it is the bbmerge output.
        /// See `IlluminaAmpliconPairMerger` for why merging is required before
        /// the full-reference-span filter can call the 244 bp DRB amplicons.
        var mappingFASTQURL: URL
        let prefixedFASTQURL: URL
        /// Mate/record count of
        /// `fastqURL` as imported. For interleaved paired input this counts
        /// EACH mate once (so a 1,000-pair sample reads 2,000 here), matching
        /// what `countWeightedFASTQRecords` returns before any merging. Use
        /// `totalFragmentCount` for a sample/run denominator instead -- this
        /// raw count exists for provenance and cache-key stability, not for
        /// percentages.
        let readCount: Int
        let readCountSource: String
        /// How the reads were prepared for mapping, recorded in provenance.
        var mergeOutcome: IlluminaAmpliconPairMerger.Outcome?
        /// How a bundle input was planned (READ-PAIRING.md). Nil for a loose file or a folder.
        var inputReads: GenotypingInputReads?

        /// The sample's read count
        /// in FRAGMENT units -- one count per physical read/amplicon
        /// molecule, whether or not its mates were merged. This is the
        /// correct denominator for retention percentages and pivot
        /// `percent_reads_unmapped`; `readCount` alone halves retention for
        /// any sample that needed on-the-fly bbmerge (the original
        /// defect), because it counts pre-merge mates while the retained
        /// side counts post-merge fragments.
        ///
        /// - When `mergeOutcome` ran bbmerge, this is the outcome's
        ///   `fragmentCount`: merged fragments, unmerged mates folded back to
        ///   one fragment each, and the merged/orphan reads of a mixed input
        ///   that bypassed bbmerge.
        /// - Otherwise `readCount` is already fragment-denominated: either
        ///   the input was single-end/pre-merged (one record per fragment),
        ///   or an explicit override (`readCountSource` other than the raw
        ///   weighted count) already reports fragments.
        var totalFragmentCount: Int {
            if let merge = mergeOutcome, merge.didMerge {
                return merge.fragmentCount
            }
            return readCount
        }

        init(
            sampleID: String,
            sourceURL: URL,
            fastqURL: URL,
            prefixedFASTQURL: URL,
            readCount: Int,
            readCountSource: String,
            mappingFASTQURL: URL? = nil,
            mergeOutcome: IlluminaAmpliconPairMerger.Outcome? = nil
        ) {
            self.sampleID = sampleID
            self.sourceURL = sourceURL
            self.fastqURL = fastqURL
            self.mappingFASTQURL = mappingFASTQURL ?? fastqURL
            self.prefixedFASTQURL = prefixedFASTQURL
            self.readCount = readCount
            self.readCountSource = readCountSource
            self.mergeOutcome = mergeOutcome
        }
    }
}
