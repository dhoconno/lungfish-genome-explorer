// BundleExportSubcommand.swift - Export a bundle to a portable artifact
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Export Subcommand

struct BundleExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export a bundle to a portable artifact",
        discussion: """
            Exports a Lungfish bundle as a deterministic OCI layout tarball.

            Examples:
              lungfish-cli bundle export MyGenome.lungfishref --export-format container --output MyGenome.oci.tar
            """
    )

    @Argument(help: "Path to the source .lungfishref bundle")
    var bundlePath: String

    // `--export-format`, not `--format`: the program-wide `--format` (text,
    // json, tsv) is parsed first and takes the value, so a subcommand option
    // of the same name can never be reached. `provenance export`, `genotype
    // export` and `fastq 12s-export` use the same spelling.
    @Option(name: .customLong("export-format"), help: "Export format")
    var format: BundleExportFormat

    @Option(name: .shortAndLong, help: "Output tarball path")
    var output: String

    @Option(name: .customLong("plugin-pack"), parsing: .upToNextOption, help: "Plugin pack ID to pin into the exported image metadata")
    var pluginPacks: [String] = []

    @Flag(name: [.customLong("quiet"), .customShort("q")], help: "Suppress non-essential output")
    var quiet: Bool = false

    func run() async throws {
        let formatter = TerminalFormatter(useColors: false)
        let bundleURL = URL(fileURLWithPath: bundlePath)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw CLIError.inputFileNotFound(path: bundlePath)
        }

        switch format {
        case .container:
            let packs = try pluginPacks.map { packID -> PluginPack in
                guard let pack = PluginPack.builtInPack(id: packID) else {
                    throw ValidationError("Unknown plugin pack: \(packID)")
                }
                return pack
            }
            let result = try await BundleContainerExportService().export(
                bundle: bundleURL,
                output: URL(fileURLWithPath: output),
                pluginPacks: packs,
                commandLine: CondaOfflinePackService.redactedCommandLine(CommandLine.arguments)
            )
            if !quiet {
                print(formatter.success("Container artifact exported: \(result.outputURL.path)"))
                print("Digest: \(result.imageDigest)")
            }
        }
    }
}
