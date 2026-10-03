// MetadataExportBioSampleSubcommand.swift - Export folder metadata as NCBI BioSample TSV
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Export BioSample Subcommand

/// Export folder metadata as NCBI BioSample TSV
struct MetadataExportBioSampleSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-biosample",
        abstract: "Export folder metadata as NCBI BioSample submission TSV",
        discussion: """
            Reads metadata from all .lungfishfastq bundles in a folder and outputs
            an NCBI BioSample-compatible TSV file. This format can be submitted
            directly to NCBI's BioSample submission portal.

            Examples:
              lungfish-cli metadata export-biosample ./RunFolder
              lungfish-cli metadata export-biosample ./RunFolder > biosample.tsv
              lungfish-cli metadata export-biosample ./RunFolder --package environmental
            """
    )

    @Argument(help: "Path to the folder containing .lungfishfastq bundles")
    var folderPath: String

    @Option(name: .long, help: "BioSample package: clinical (default) or environmental")
    var package: String = "clinical"

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let folderURL = URL(fileURLWithPath: folderPath)
        guard FileManager.default.fileExists(atPath: folderPath) else {
            throw CLIError.inputFileNotFound(path: folderPath)
        }

        let resolved = FASTQFolderMetadata.loadResolved(from: folderURL)
        guard !resolved.samples.isEmpty else {
            if !globalOptions.quiet {
                let formatter = TerminalFormatter(useColors: globalOptions.useColors)
                print(formatter.info("No .lungfishfastq bundles found in \(folderURL.lastPathComponent)"))
            }
            return
        }

        let orderedSamples = resolved.sampleOrder.compactMap { resolved.samples[$0] }

        let bioPackage: NCBIBioSampleExporter.BioSamplePackage
        switch package.lowercased() {
        case "environmental", "env":
            bioPackage = .pathogenEnvironmental
        default:
            bioPackage = .pathogenClinical
        }

        let tsv = NCBIBioSampleExporter.export(samples: orderedSamples, package: bioPackage)
        print(tsv, terminator: "")
    }
}
