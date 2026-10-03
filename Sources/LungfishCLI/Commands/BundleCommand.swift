// BundleCommand.swift - Reference bundle management commands
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Manage reference genome bundles (.lungfishref)
struct BundleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Manage reference genome bundles (.lungfishref)",
        discussion: """
            Reference genome bundles are directory packages containing a genome sequence,
            annotations, variants, and signal tracks in optimized binary formats.

            Use these commands to create, inspect, and validate bundles.

            Examples:
              lungfish-cli bundle info MyGenome.lungfishref
              lungfish-cli bundle create --fasta genome.fa --name "My Genome" --output ./
              lungfish-cli bundle validate MyGenome.lungfishref
            """,
        subcommands: [
            BundleInfoSubcommand.self,
            BundleCreateSubcommand.self,
            BundleExtractAnnotationsSubcommand.self,
            BundleDeduplicateAlignmentsSubcommand.self,
            BundleMarkDuplicatesSubcommand.self,
            BundleExportSubcommand.self,
            BundleValidateSubcommand.self,
            BundleListSubcommand.self,
        ],
        defaultSubcommand: BundleInfoSubcommand.self
    )
}
