// BundleDeduplicateAlignmentsSubcommand.swift - Create a bundle with duplicate reads removed from alignment tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Deduplicate Alignments Subcommand

struct BundleDeduplicateAlignmentsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deduplicate-alignments",
        abstract: "Create a bundle with duplicate reads removed from alignment tracks",
        discussion: """
            Copies a .lungfishref bundle, runs the shared duplicate-removal workflow on
            every alignment track, and records reproducibility provenance in the output bundle.

            Examples:
              lungfish-cli bundle deduplicate-alignments MyGenome.lungfishref
              lungfish-cli bundle deduplicate-alignments MyGenome.lungfishref --output MyGenome-dedup.lungfishref
            """
    )

    @Argument(help: "Path to the source .lungfishref bundle")
    var bundlePath: String

    @Option(name: [.customLong("output"), .customShort("o")], help: "Output .lungfishref bundle path")
    var output: String?

    @OptionGroup var globalOptions: TextAndJSONGlobalOptions

    func run() async throws {
        let resolvedOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
        var command = [CLICommandIdentity.executableName, "bundle", "deduplicate-alignments", bundlePath]
        if let output {
            command += ["--output", output]
        }
        _ = try await CLIDeduplicatedBundleSupport.run(
            sourceBundlePath: bundlePath,
            outputBundlePath: output,
            outputFormat: resolvedOptions.outputFormat,
            quiet: resolvedOptions.quiet,
            command: command
        ) { print($0) }
    }
}
