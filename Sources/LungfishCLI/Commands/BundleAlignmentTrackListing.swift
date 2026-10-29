// BundleAlignmentTrackListing.swift - The alignment-track rows bundle info and bundle list print
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The alignment-track rows `bundle info` and `bundle list` print.
///
/// Alignment tracks were the one track kind both commands left out, so a
/// bundle with mapped reads looked empty from the command line.
enum BundleAlignmentTrackListing {
    static let tableHeaders = ["ID", "Name", "Format", "Mapped Reads", "Path"]

    /// Where a listed count comes from, which decides the words beside it.
    enum CountBasis: Equatable {
        /// Flagstat's primary lines, so the count is reads.
        case reads
        /// A database without the primary lines, so the count is alignment records (flagstat `mapped` or idxstats).
        case alignments
        /// The manifest's copy, because the track's statistics database could not be read or holds no counts.
        case manifest
        /// The manifest's copy, with no statistics database to ask.
        case stored

        /// The word `bundle info --format json` prints for this basis. Both copies of the manifest read `manifest`, since the
        /// manifest does not record what its count counts.
        var jsonWord: String {
            switch self {
            case .reads: "reads"
            case .alignments: "alignments"
            case .manifest, .stored: "manifest"
            }
        }
    }

    static func tableRows(_ tracks: [AlignmentTrackInfo], bundleURL: URL? = nil, formatter: TerminalFormatter) -> [[String]] {
        tracks.map { track in
            let listed = listedMapped(of: track, in: bundleURL)
            return [
                track.id,
                track.name,
                track.format.rawValue,
                listed.mapped.map { cellWords(formatter.number(Int($0)), listed.basis) } ?? "-",
                track.sourcePath,
            ]
        }
    }

    static func listLines(_ tracks: [AlignmentTrackInfo], bundleURL: URL? = nil, formatter: TerminalFormatter) -> [String] {
        tracks.map { track in
            let listed = listedMapped(of: track, in: bundleURL)
            let reads = listed.mapped.map { ", \(listWords(formatter.number(Int($0)), listed.basis))" } ?? ""
            return "\(track.id): \(track.name) (\(track.format.rawValue)\(reads)) \(track.sourcePath)"
        }
    }

    /// The mapped count a track lists and what it counts. Its stats database holds flagstat's primary counts, which are
    /// reads. A database without them gives alignment records, which count each supplementary alignment again, from flagstat's
    /// `mapped` line or from idxstats. A database that cannot be read, or holds no counts, leaves the manifest's copy, which a
    /// bundle written before this release filled from idxstats, so the listing says that the count is the manifest's.
    static func listedMapped(of track: AlignmentTrackInfo, in bundleURL: URL?) -> (mapped: Int64?, basis: CountBasis) {
        guard let bundleURL, let path = track.metadataDBPath else { return (track.mappedReadCount, .stored) }
        if let database = try? AlignmentMetadataDatabase(url: bundleURL.appendingPathComponent(path)) {
            if let reads = database.primaryReadCounts() { return (reads.mapped, .reads) }
            if let mapped = database.flagStats().first(where: { $0.category == "mapped" }) {
                return (mapped.qcPass + mapped.qcFail, .alignments)
            }
            if !database.chromosomeStats().isEmpty { return (database.totalMappedReads(), .alignments) }
        }
        return (track.mappedReadCount, .manifest)
    }

    /// The words after a count in `bundle list`.
    private static func listWords(_ number: String, _ basis: CountBasis) -> String {
        switch basis {
        case .reads, .stored: "\(number) mapped reads"
        case .alignments: "\(number) mapped alignments"
        case .manifest: "\(number) mapped from the manifest because its statistics database has no readable counts"
        }
    }

    /// The Mapped Reads cell of `bundle info`.
    private static func cellWords(_ number: String, _ basis: CountBasis) -> String {
        switch basis {
        case .reads, .stored: number
        case .alignments: "\(number) (alignments)"
        case .manifest: "\(number) (from the manifest)"
        }
    }

    /// The reads a track lists as mapped and as unmapped. Its stats database holds flagstat's primary counts, which are
    /// reads. A bundle written before this release holds the idxstats sum in its manifest, which counts each supplementary
    /// alignment again, so the database comes first and the manifest's numbers stay for a track with no database or no
    /// primary lines. The JSON form of `bundle info` prints these, with the `basis` that says what the mapped count counts.
    /// The mapped count is the one `bundle list` shows, and the unmapped count stays the manifest's unless it is reads.
    static func readCounts(of track: AlignmentTrackInfo, in bundleURL: URL?) -> (mapped: Int64?, unmapped: Int64?, basis: CountBasis) {
        let listed = listedMapped(of: track, in: bundleURL)
        guard listed.basis == .reads, let bundleURL, let path = track.metadataDBPath,
              let reads = (try? AlignmentMetadataDatabase(url: bundleURL.appendingPathComponent(path)))?.primaryReadCounts() else {
            return (listed.mapped, track.unmappedReadCount, listed.basis)
        }
        return (reads.mapped, reads.unmapped, .reads)
    }

    /// What each track's printed count counts, by track id, for the `mapped_read_count_basis` key of `bundle info --format json`.
    static func countBases(_ tracks: [AlignmentTrackInfo], in bundleURL: URL) -> [String: String] {
        Dictionary(
            tracks.map { ($0.id, readCounts(of: $0, in: bundleURL).basis.jsonWord) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The tracks with their counts set to `readCounts(of:in:)`, for output that prints the manifest.
    static func withReads(_ tracks: [AlignmentTrackInfo], in bundleURL: URL) -> [AlignmentTrackInfo] {
        tracks.map { track in
            let counts = readCounts(of: track, in: bundleURL)
            return track.withReadCounts(mapped: counts.mapped, unmapped: counts.unmapped)
        }
    }
}
