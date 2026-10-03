// SRASubcommand.swift - Search and download from SRA (Sequence Read Archive)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - SRA Subcommand

/// Search and download from SRA (Sequence Read Archive)
struct SRASubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sra",
        abstract: "Search and download from SRA (Sequence Read Archive)",
        discussion: """
            Search for sequencing reads in the NCBI Sequence Read Archive and
            download FASTQ files. Downloads use ENA mirrors for direct HTTP access
            (no SRA Toolkit required).

            Examples:
              lungfish-cli fetch sra search "SARS-CoV-2 Illumina" --limit 10
              lungfish-cli fetch sra download SRR11140748 --output-dir ./fastq
              lungfish-cli fetch sra info SRR11140748
            """,
        subcommands: [
            SRASearchSubcommand.self,
            SRADownloadSubcommand.self,
            SRAInfoSubcommand.self,
        ],
        defaultSubcommand: SRASearchSubcommand.self
    )
}
