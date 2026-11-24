// ReadStyleSection+MeanDepth.swift - Per-sequence read statistics and the measured mean depth
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Per-chromosome read statistics for display.
public struct ChromosomeReadStat: Identifiable {
    public var id: String { chromosome }
    public let chromosome: String
    public let length: Int64
    public let mappedReads: Int64
    public let unmappedReads: Int64
    /// The alignment file the depth is measured from. Nil where no single file stands for the sequence.
    public let alignmentURL: URL?
    /// The mean depth over the whole sequence as `samtools coverage` measured it. Nil until it is measured, and where it cannot be.
    public let measuredMeanDepth: Double?

    public init(
        chromosome: String, length: Int64, mappedReads: Int64, unmappedReads: Int64,
        alignmentURL: URL? = nil, measuredMeanDepth: Double? = nil
    ) {
        self.chromosome = chromosome
        self.length = length
        self.mappedReads = mappedReads
        self.unmappedReads = unmappedReads
        self.alignmentURL = alignmentURL
        self.measuredMeanDepth = measuredMeanDepth
    }

    /// The depth the Inspector shows: the measured mean depth, or nil for no row. No read length is assumed (EST-COVERAGE-150BP).
    public var estimatedCoverage: Double? {
        length > 0 ? measuredMeanDepth : nil
    }

    func withMeasuredMeanDepth(_ depth: Double) -> ChromosomeReadStat {
        ChromosomeReadStat(
            chromosome: chromosome, length: length, mappedReads: mappedReads, unmappedReads: unmappedReads,
            alignmentURL: alignmentURL, measuredMeanDepth: depth
        )
    }
}

extension ReadStyleSectionViewModel {
    /// A one-sequence bundle shows its mean depth. It is measured off the main thread, so none shows until it returns,
    /// and none where it cannot be measured. `stats` gains the alignment file the figure is measured from.
    func startMeanDepthMeasurement(
        for stats: inout [ChromosomeReadStat],
        databases: [(trackID: String, db: AlignmentMetadataDatabase)],
        countedTrackIDs: Set<String>,
        in bundle: ReferenceBundle
    ) {
        guard stats.count == 1, let only = stats.first,
              let source = databases.first(where: { countedTrackIDs.contains($0.trackID) && !$0.db.chromosomeStats().isEmpty }),
              let track = bundle.alignmentTrack(id: source.trackID) else { return }
        let alignmentURL = bundle.url.appendingPathComponent(track.sourcePath)
        let chromosome = only.chromosome
        stats = [ChromosomeReadStat(
            chromosome: chromosome, length: only.length, mappedReads: only.mappedReads,
            unmappedReads: only.unmappedReads, alignmentURL: alignmentURL
        )]
        Task { [weak self] in
            guard let depth = await AlignmentMeanDepth.measure(alignmentURL: alignmentURL, chromosome: chromosome) else { return }
            guard let self else { return }
            self.chromosomeStats = self.chromosomeStats.map {
                $0.alignmentURL == alignmentURL && $0.chromosome == chromosome ? $0.withMeasuredMeanDepth(depth) : $0
            }
        }
    }
}
