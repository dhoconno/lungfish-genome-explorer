// RNASeqCommand.swift - The `lungfish-cli rnaseq` group (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser

/// The RNA-seq commands. RS-REFSET adds the group (P5-PREMISES Q-A2), and later lanes add their leaves.
struct RNASeqCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rnaseq",
        abstract: "Build RNA-seq reference sets and count RNA-seq reads",
        subcommands: [ReferenceSetSubcommand.self, IndexSubcommand.self, InstallReferenceSubcommand.self, QuantSubcommand.self, RNASeqExportSubcommand.self, RNASeqPseudobulkSubcommand.self,
                      RNASeqQualitySubcommand.self, RNASeqIndexPlanSubcommand.self, RNASeqIndexAdoptSubcommand.self, RNASeqSoloPlanSubcommand.self,
                      RNASeqCellMapSubcommand.self]
    )
}
