// FASTQMixedLayoutHint+Join.swift - The read roles of one file that joins the reads of several sources end to end
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension FASTQMixedLayoutHint {

    /// The reads of one source of a joined file, as its files in the order
    /// the join writes them and the roles the source records for its reads.
    public struct JoinedSource: Sendable {
        public let files: [URL]
        public let recordedRoles: ReadClassification?

        public init(files: [URL], recordedRoles: ReadClassification?) {
            self.files = files
            self.recordedRoles = recordedRoles
        }
    }

    /// The reads of a joined file by kind.
    public struct JoinedReadCounts: Sendable, Equatable {
        public let pairs: Int
        public let merged: Int
        public let unpaired: Int

        /// The pairing the joined file records, which follows its counts
        /// (``FASTQMixedLayoutHint/pairingMode(pairs:singles:)``).
        public var pairingMode: IngestionMetadata.PairingMode {
            FASTQMixedLayoutHint.pairingMode(pairs: pairs, singles: merged + unpaired)
        }

        /// The roles the joined file `filename` records, or nil when it holds
        /// no pair or no single read, which needs no hint.
        public func classification(filename: String) -> ReadClassification? {
            FASTQMixedLayoutHint.classification(pairs: pairs, merged: merged, unpaired: unpaired, filename: filename)
        }
    }

    /// The reads of a file that holds the files of `sources` joined end to
    /// end in order.
    ///
    /// The files are read as the one stream the joined file is, by the
    /// pairing rule of the layout scan, so the counts are the joined file's
    /// own. Each read without a mate takes its role from the source it came
    /// from (``singleReads(_:byRecordedRoles:)``), since a join copies reads
    /// and changes none.
    public static func readCounts(joining sources: [JoinedSource]) throws -> JoinedReadCounts {
        let counts = try countPairsAndSingles(acrossJoined: sources.map(\.files))
        var merged = 0
        var unpaired = 0
        for (source, singles) in zip(sources, counts.singlesPerSource) {
            let byRole = singleReads(singles, byRecordedRoles: source.recordedRoles)
            merged += byRole.merged
            unpaired += byRole.unpaired
        }
        return JoinedReadCounts(pairs: counts.pairs, merged: merged, unpaired: unpaired)
    }

    /// The adjacent mate pairs of the files of `sources` read end to end as
    /// one stream, and the reads without a mate each source holds. A pair
    /// whose two records lie in two sources counts once, as the joined file
    /// holds it.
    public static func countPairsAndSingles(
        acrossJoined sources: [[URL]]
    ) throws -> (pairs: Int, singlesPerSource: [Int]) {
        var pairs = 0
        var singlesPerSource = Array(repeating: 0, count: sources.count)
        var pending: (header: String, source: Int)?
        for (index, files) in sources.enumerated() {
            for file in files {
                var lineIndex = 0
                try file.forEachLineAutoDecompressing { line in
                    defer { lineIndex += 1 }
                    guard lineIndex % 4 == 0, line.hasPrefix("@") else { return }
                    let header = String(line.dropFirst())
                    if let previous = pending {
                        if FASTQReadLayoutClassifier.areMates(previous.header, header) {
                            pairs += 1
                            pending = nil
                        } else {
                            singlesPerSource[previous.source] += 1
                            pending = (header, index)
                        }
                    } else {
                        pending = (header, index)
                    }
                }
            }
        }
        if let pending { singlesPerSource[pending.source] += 1 }
        return (pairs, singlesPerSource)
    }

    /// The merged reads and the reads without a mate among `singles` single
    /// reads of a source whose recorded roles are `roles`. A source that
    /// records merged reads and no orphan holds merged single reads, one
    /// that records both holds its recorded merged reads first, and any
    /// other holds reads without a mate.
    public static func singleReads(
        _ singles: Int,
        byRecordedRoles roles: ReadClassification?
    ) -> (merged: Int, unpaired: Int) {
        guard let roles, roles.mergedReadCount > 0 else { return (0, singles) }
        guard roles.unpairedReadCount > 0 else { return (singles, 0) }
        let merged = min(singles, roles.mergedReadCount)
        return (merged, singles - merged)
    }
}
