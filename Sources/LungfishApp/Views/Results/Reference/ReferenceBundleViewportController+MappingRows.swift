// ReferenceBundleViewportController+MappingRows.swift - Track stats for mapping rows, read once and off the main actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// What a mapping row refresh needs from one alignment track's stats
/// database, read with one open of it and off the main actor. It holds no
/// contig row. The database's per-sequence counts come from idxstats, which
/// counts supplementary records, and it measures no depth, breadth, MAPQ or
/// identity. The table shows the record's rows or the summary builder's rows.
struct AlignmentTrackStatsSnapshot: Sendable {
    /// Primary reads that mapped and all primary reads, which flagstat's
    /// `primary mapped` and `primary` lines count. The `mapped` and `total`
    /// lines and idxstats count supplementary records too, so they read high.
    /// `countsAreReads` is false for those alignment records and for the manifest's
    /// counts, which a bundle from before the primary lines wrote from idxstats.
    /// A total of 0 means that none was measured.
    let mappedReads: Int
    let totalReads: Int
    let countsAreReads: Bool
    /// Each canonical sample with its read groups, then any unmatched read
    /// groups as a sample with no identity.
    let sampleReadGroups: [(sampleID: String?, readGroupIDs: Set<String>)]
    /// One persisted sample and no unmatched read groups, so that sample's
    /// rows are the rows of the whole BAM.
    let sampleCoversWholeBAM: Bool
    /// Where the import read this track's BAM from (`original_source_path`).
    let importedFromPath: String?

    static func read(track: AlignmentTrackInfo, databaseURL: URL?) async -> AlignmentTrackStatsSnapshot {
        await Task.detached(priority: .userInitiated) {
            readNow(track: track, databaseURL: databaseURL)
        }.value
    }

    /// Whether the track was imported from the mapping result's own BAM, so the
    /// result's rows are this track's rows.
    func isImported(from resultBAMURL: URL?) -> Bool {
        Self.isImported(fromPath: importedFromPath, resultBAM: resultBAMURL)
    }

    /// Compares the last two path components, the result folder and the BAM name,
    /// since a project that was moved or cloned keeps both but not the full path.
    /// A filtered track names the track it came from, which lives in the viewer
    /// bundle's `alignments` folder and not beside the result.
    static func isImported(fromPath path: String?, resultBAM: URL?) -> Bool {
        guard let path, !path.isEmpty, let resultBAM else { return false }
        let imported = URL(fileURLWithPath: path).standardizedFileURL
        let own = resultBAM.standardizedFileURL
        return imported.lastPathComponent == own.lastPathComponent
            && imported.deletingLastPathComponent().lastPathComponent
                == own.deletingLastPathComponent().lastPathComponent
    }

    private static func readNow(track: AlignmentTrackInfo, databaseURL: URL?) -> AlignmentTrackStatsSnapshot {
        let manifestMapped = Int(clamping: track.mappedReadCount ?? 0)
        let manifestTotal = manifestMapped + Int(clamping: track.unmappedReadCount ?? 0)
        guard let databaseURL, let database = try? AlignmentMetadataDatabase(url: databaseURL) else {
            return AlignmentTrackStatsSnapshot(
                mappedReads: manifestMapped,
                totalReads: manifestTotal,
                countsAreReads: false,
                sampleReadGroups: [(nil, [])],
                sampleCoversWholeBAM: false,
                importedFromPath: nil
            )
        }
        let counts = readCounts(in: database) ?? (manifestMapped, manifestTotal, false)
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
        return AlignmentTrackStatsSnapshot(
            mappedReads: counts.mapped,
            totalReads: counts.total,
            countsAreReads: counts.areReads,
            sampleReadGroups: samples,
            sampleCoversWholeBAM: samples.count == 1 && samples[0].sampleID != nil
                && resolution?.unmatchedReadGroupIDs.isEmpty == true,
            importedFromPath: database.getFileInfo("original_source_path")
        )
    }

    /// The counts of the database, reads from `primaryReadCounts()` and then `areReads` is true. A flagstat
    /// that predates the primary lines (samtools before 1.9) gives its `mapped` and `total` record
    /// counts, as the mapping record's own parse does, and a database without
    /// flagstat gives its per-sequence totals, which are record counts too, and then `areReads` is
    /// false. `nil` sends the caller to the counts the manifest declares.
    private static func readCounts(in database: AlignmentMetadataDatabase) -> (mapped: Int, total: Int, areReads: Bool)? {
        if let reads = database.primaryReadCounts() {
            return (Int(clamping: reads.mapped), Int(clamping: reads.mapped + reads.unmapped), true)
        }
        if let counts = flagStatCounts(database.flagStats(), mapped: "mapped", total: "total") {
            return (counts.mapped, counts.total, false)
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
        return (Int(clamping: databaseMapped), Int(clamping: databaseTotal.partialValue), false)
    }

    private static func flagStatCounts(
        _ flagStats: [AlignmentMetadataDatabase.FlagStatRecord],
        mapped mappedCategory: String,
        total totalCategory: String
    ) -> (mapped: Int, total: Int)? {
        guard let totalRecord = flagStats.first(where: { $0.category == totalCategory }),
              let mappedRecord = flagStats.first(where: { $0.category == mappedCategory }) else {
            return nil
        }
        let total = totalRecord.qcPass.addingReportingOverflow(totalRecord.qcFail)
        let mapped = mappedRecord.qcPass.addingReportingOverflow(mappedRecord.qcFail)
        guard !total.overflow,
              !mapped.overflow,
              total.partialValue >= 0,
              mapped.partialValue >= 0,
              total.partialValue >= mapped.partialValue else {
            return nil
        }
        return (Int(clamping: mapped.partialValue), Int(clamping: total.partialValue))
    }
}

/// A summary build that ended without an error and without a row for a track that holds
/// mapped reads, as a managed samtools wrapper does when a streamed subcommand fails.
struct MappingSummaryReturnedNoRows: LocalizedError {
    var errorDescription: String? { "samtools returned no rows for a track that holds mapped reads" }
}

extension ReferenceBundleViewportController {
    /// The summary bar words for the tracks whose alignment statistics could not be
    /// measured, with what to try next and then the reason of the first, since a long reason can clip
    /// in the bar. `nil` when every track was measured.
    static func measurementFailureWords(_ failures: [(track: String, reason: String)]) -> String? {
        guard let first = failures.first else { return nil }
        var seen = Set<String>()
        let tracks = failures.map(\.track).filter { seen.insert($0).inserted }
        return "Could not measure the alignment statistics for \(tracks.joined(separator: ", ")). Open the mapping again to try once more, or run the mapping again if it keeps failing. Reason: \(first.reason)"
    }

    /// The summary bar line for the alignment track on show. The counts are reads or alignment records, and the line
    /// says which. Without a total a percentage would be one nobody measured, so the line gives none, says that the
    /// total is unknown and says what to try.
    static func alignmentSummaryText(track: String, mapped: Int, total: Int, areReads: Bool) -> String {
        let unit = areReads ? "reads" : "alignments"
        guard total > 0 else {
            return "\(track) — \(mapped.formatted()) \(unit) mapped, total unknown so no percentage. Run the mapping or import the alignment again to count its reads."
        }
        let percent = String(format: "%.1f%%", Double(mapped) / Double(total) * 100)
        return "\(track) — \(mapped.formatted()) / \(total.formatted()) \(unit) mapped (\(percent))"
    }

    /// The tip of the summary line when its counts are alignments or its total is unknown, `nil` for measured reads. It
    /// holds the reason and the next step in full, since the line itself can clip on a narrow pane.
    static func alignmentSummaryTip(total: Int, areReads: Bool) -> String? {
        if total <= 0 {
            return "The total number of reads was not stored, so there is no percentage. Run the mapping or import the alignment again to count its reads."
        }
        return areReads ? nil : "These counts are alignments, so a read that aligns in more than one place counts once for each place. Run the mapping or import the alignment again to count its reads."
    }

    /// The summary line with the words of an alignment summary build after it. The words of a build that
    /// failed come in orange. While a build measures tracks whose rows the table does not show yet, "Measuring"
    /// comes in the secondary colour, since waiting is no warning. Assigning the failure words ends the
    /// measuring words (see `alignmentTrackSummaryWarning`), and so does the build's own rows.
    func withSummaryWarning(_ text: String, tip: String? = nil) -> String {
        summaryLabel.toolTip = tip
        if let alignmentTrackSummaryWarning {
            summaryLabel.textColor = .systemOrange
            summaryLabel.toolTip = alignmentTrackSummaryWarning
            return text + " — Warning: \(alignmentTrackSummaryWarning)"
        }
        guard let alignmentTrackSummaryProgress, !alignmentTrackSummaryProgress.isEmpty else { return text }
        return text + " — Measuring the alignment statistics for \(alignmentTrackSummaryProgress)…"
    }

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
