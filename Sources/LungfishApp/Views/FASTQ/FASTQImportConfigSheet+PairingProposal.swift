// FASTQImportConfigSheet+PairingProposal.swift - The Pairing item the Import FASTQ sheet proposes for lone files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import UniformTypeIdentifiers

extension FASTQImportConfigSheet {
    /// Records read from each lone file when proposing its pairing.
    nonisolated static let pairingProposalRecordLimit = 2_000
    /// Lone files read when proposing a pairing for a batch.
    nonisolated static let pairingProposalFileLimit = 4

    /// The Pairing popup item the sheet proposes: Paired-end when R1/R2 files
    /// were matched, Interleaved when every lone file (up to
    /// ``pairingProposalFileLimit``) alternates mates in its first
    /// ``pairingProposalRecordLimit`` records, otherwise Single-end.
    ///
    /// A proposal is not a choice: left untouched, the import runs with
    /// `--pairing auto`, which reads every lone file in full on its own.
    nonisolated static func proposedPairingIndex(for pairs: [FASTQFilePair]) -> Int {
        if pairs.contains(where: { $0.isPaired }) { return 1 }
        let loneFiles = pairs.prefix(pairingProposalFileLimit).map(\.r1)
        guard !loneFiles.isEmpty else { return 0 }
        let allInterleaved = loneFiles.allSatisfy {
            FASTQReadLayoutClassifier.classify(inputURL: $0, limit: pairingProposalRecordLimit).layout
                == .strictlyInterleaved
        }
        return allInterleaved ? 2 : 0
    }
}
