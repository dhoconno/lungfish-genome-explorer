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

    static func tableRows(_ tracks: [AlignmentTrackInfo], bundleURL: URL? = nil, formatter: TerminalFormatter) -> [[String]] {
        tracks.map { track in
            [
                track.id,
                track.name,
                track.format.rawValue,
                mappedReads(of: track, in: bundleURL).map { formatter.number(Int($0)) } ?? "-",
                track.sourcePath,
            ]
        }
    }

    static func listLines(_ tracks: [AlignmentTrackInfo], bundleURL: URL? = nil, formatter: TerminalFormatter) -> [String] {
        tracks.map { track in
            let reads = mappedReads(of: track, in: bundleURL).map { ", \(formatter.number(Int($0))) mapped reads" } ?? ""
            return "\(track.id): \(track.name) (\(track.format.rawValue)\(reads)) \(track.sourcePath)"
        }
    }

    /// The reads a track lists as mapped. Its stats database holds flagstat's primary count, which is reads. A bundle
    /// written before this release holds the idxstats sum in its manifest, which counts each supplementary alignment
    /// again, so the database comes first and the manifest's number stays for a track with no database or no primary lines.
    static func mappedReads(of track: AlignmentTrackInfo, in bundleURL: URL?) -> Int64? {
        if let bundleURL, let path = track.metadataDBPath,
           let database = try? AlignmentMetadataDatabase(url: bundleURL.appendingPathComponent(path)),
           let primary = database.primaryReadCounts() {
            return primary.mapped
        }
        return track.mappedReadCount
    }
}
