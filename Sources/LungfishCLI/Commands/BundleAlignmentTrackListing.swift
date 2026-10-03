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

    static func tableRows(_ tracks: [AlignmentTrackInfo], formatter: TerminalFormatter) -> [[String]] {
        tracks.map { track in
            [
                track.id,
                track.name,
                track.format.rawValue,
                track.mappedReadCount.map { formatter.number(Int($0)) } ?? "-",
                track.sourcePath,
            ]
        }
    }

    static func listLines(_ tracks: [AlignmentTrackInfo], formatter: TerminalFormatter) -> [String] {
        tracks.map { track in
            let reads = track.mappedReadCount.map { ", \(formatter.number(Int($0))) mapped reads" } ?? ""
            return "\(track.id): \(track.name) (\(track.format.rawValue)\(reads)) \(track.sourcePath)"
        }
    }
}
