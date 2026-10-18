// ReferenceBundleViewportController+MappingRows.swift - Track stats for mapping rows, read once and off the main actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// What a mapping row refresh needs from one alignment track's stats
/// database, read with one open of it and off the main actor.
struct AlignmentTrackStatsSnapshot: Sendable {
    let mappedReads: Int
    let totalReads: Int
    /// Each canonical sample with its read groups, then any unmatched read
    /// groups as a sample with no identity.
    let sampleReadGroups: [(sampleID: String?, readGroupIDs: Set<String>)]
    /// One persisted sample and no unmatched read groups, so the track's
    /// aggregate stats are truthful for that sample.
    let canUseAggregateFallback: Bool
    /// Rows from the stored per-sequence stats, only the sequences with reads.
    let fallbackRows: [MappingContigSummary]?

    static func read(track: AlignmentTrackInfo, databaseURL: URL?) async -> AlignmentTrackStatsSnapshot {
        await Task.detached(priority: .userInitiated) {
            readNow(track: track, databaseURL: databaseURL)
        }.value
    }

    private static func readNow(track: AlignmentTrackInfo, databaseURL: URL?) -> AlignmentTrackStatsSnapshot {
        let manifestMapped = Int(clamping: track.mappedReadCount ?? 0)
        let manifestTotal = manifestMapped + Int(clamping: track.unmappedReadCount ?? 0)
        guard let databaseURL, let database = try? AlignmentMetadataDatabase(url: databaseURL) else {
            return AlignmentTrackStatsSnapshot(
                mappedReads: manifestMapped,
                totalReads: manifestTotal,
                sampleReadGroups: [(nil, [])],
                canUseAggregateFallback: false,
                fallbackRows: nil
            )
        }
        let counts = readCounts(in: database) ?? (manifestMapped, manifestTotal)
        let explicitSampleID = track.sampleNames.count == 1 ? track.sampleNames[0] : nil
        let resolution = try? BAMSampleIdentityResolver.resolve(
            readGroups: database.readGroups(),
            trackIDs: [track.id],
            explicitResultSampleID: explicitSampleID,
            trackSampleIDs: explicitSampleID.map { [track.id: $0] } ?? [:]
        )
        var samples: [(sampleID: String?, readGroupIDs: Set<String>)]
        if let resolution, !resolution.identityIndex.canonicalSampleIDs.isEmpty {
            samples = resolution.identityIndex.canonicalSampleIDs.sorted().map {
                ($0, resolution.identityIndex.readGroupIDs(forCanonicalSampleID: $0))
            }
            if !resolution.unmatchedReadGroupIDs.isEmpty {
                samples.append((nil, resolution.unmatchedReadGroupIDs))
            }
        } else {
            samples = [(nil, resolution?.unmatchedReadGroupIDs ?? [])]
        }
        let rows = database.chromosomeStats(mappedOnly: true).map { stat in
            MappingContigSummary(
                contigName: stat.chromosome,
                contigLength: Int(clamping: stat.length),
                mappedReads: Int(clamping: stat.mappedReads),
                mappedReadPercent: counts.total > 0 ? Double(stat.mappedReads) / Double(counts.total) * 100 : 0,
                meanDepth: 0,
                coverageBreadth: 0,
                medianMAPQ: 0,
                meanIdentity: 0
            )
        }
        return AlignmentTrackStatsSnapshot(
            mappedReads: counts.mapped,
            totalReads: counts.total,
            sampleReadGroups: samples,
            canUseAggregateFallback: samples.count == 1 && samples[0].sampleID != nil
                && resolution?.unmatchedReadGroupIDs.isEmpty == true,
            fallbackRows: rows.isEmpty ? nil : rows
        )
    }

    /// Mapped and total reads from flagstat, else from the per-sequence
    /// stats. `nil` sends the caller to the counts the manifest declares.
    private static func readCounts(in database: AlignmentMetadataDatabase) -> (mapped: Int, total: Int)? {
        let flagStats = database.flagStats()
        if let totalRecord = flagStats.first(where: { $0.category == "total" }),
           let mappedRecord = flagStats.first(where: { $0.category == "mapped" }) {
            let total = totalRecord.qcPass.addingReportingOverflow(totalRecord.qcFail)
            let mapped = mappedRecord.qcPass.addingReportingOverflow(mappedRecord.qcFail)
            if !total.overflow,
               !mapped.overflow,
               total.partialValue >= 0,
               mapped.partialValue >= 0,
               total.partialValue >= mapped.partialValue {
                return (Int(clamping: mapped.partialValue), Int(clamping: total.partialValue))
            }
        }
        let databaseMapped = database.totalMappedReads()
        let databaseUnmapped = database.totalUnmappedReads()
        let databaseTotal = databaseMapped.addingReportingOverflow(databaseUnmapped)
        guard databaseMapped >= 0,
              databaseUnmapped >= 0,
              !databaseTotal.overflow,
              databaseTotal.partialValue > 0 else {
            return nil
        }
        return (Int(clamping: databaseMapped), Int(clamping: databaseTotal.partialValue))
    }
}

extension ReferenceBundleViewportController {
    /// FASTA descriptions for the sequences the table shows, never a
    /// dictionary over every sequence of a large reference.
    static func fastaDescriptions(
        for rows: [MappingContigSummary],
        in manifest: BundleManifest?
    ) -> [String: String] {
        guard let chromosomes = manifest?.genome?.chromosomes, !rows.isEmpty else { return [:] }
        let shown = Set(rows.map(\.contigName))
        var descriptions: [String: String] = [:]
        for chromosome in chromosomes where shown.contains(chromosome.name) {
            if let description = chromosome.fastaDescription, !description.isEmpty {
                descriptions[chromosome.name] = description
            }
        }
        return descriptions
    }
}
