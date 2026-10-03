// BundleMarkDuplicatesSubcommand.swift - Add duplicate-marked copies of a bundle's alignment tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Mark Duplicates Subcommand

struct BundleMarkDuplicatesSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mark-duplicates",
        abstract: "Add duplicate-marked copies of a bundle's alignment tracks, keeping the originals",
        discussion: """
            Runs the shared samtools markdup workflow on every unmarked alignment track in a
            .lungfishref bundle and attaches each result as a new "[dup-marked]" track under
            alignments/marked/. The source tracks are kept on disk and renamed "[unmarked]";
            nothing is deleted. Running the command again on the same bundle is a no-op error
            once every track has a marked copy. This is the CLI equivalent of the Inspector's
            "Mark Duplicates in Bundle Tracks" action.

            Examples:
              lungfish-cli bundle mark-duplicates MyGenome.lungfishref
              lungfish-cli bundle mark-duplicates MyGenome.lungfishref --format json
            """
    )

    @Argument(help: "Path to the .lungfishref bundle to update in place")
    var bundlePath: String

    @OptionGroup var globalOptions: TextAndJSONGlobalOptions

    func run() async throws {
        let resolvedOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
        _ = try await CLIMarkDuplicatesBundleSupport.run(
            bundlePath: bundlePath,
            outputFormat: resolvedOptions.outputFormat,
            quiet: resolvedOptions.quiet,
            command: [CLICommandIdentity.executableName, "bundle", "mark-duplicates", bundlePath]
        ) { print($0) }
    }
}
