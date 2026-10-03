// ENASubcommand.swift - Search and download from ENA (European Nucleotide Archive)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - ENA Subcommand

/// Search and download from ENA (European Nucleotide Archive)
struct ENASubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ena",
        abstract: "Search and download from ENA (European Nucleotide Archive)",
        discussion: """
            Search for sequences and reads in the European Nucleotide Archive.
            ENA provides direct FASTQ download URLs without requiring the SRA Toolkit.

            Examples:
              lungfish-cli fetch ena search "Ebola virus" --limit 10
              lungfish-cli fetch ena reads SRR11140748
              lungfish-cli fetch ena fasta NC_002549
            """,
        subcommands: [
            ENASearchSubcommand.self,
            ENAReadsSubcommand.self,
            ENAFastaSubcommand.self,
        ],
        defaultSubcommand: ENASearchSubcommand.self
    )
}
