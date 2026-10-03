// SRAInfoSubcommand.swift - Get info about an SRA run
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Get info about an SRA run
struct SRAInfoSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Get information about an SRA run"
    )

    @Argument(help: "SRA run accession (e.g., SRR11140748)")
    var accession: String

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching info for \(accession)..."))
        }

        let service = SRAService(ncbiService: NCBIService(apiKey: apiKey))

        do {
            // Search for the specific accession
            let searchQuery = SearchQuery(term: accession, limit: 1)
            let results = try await service.search(searchQuery)

            guard let run = results.runs.first else {
                throw CLIError.networkError(reason: "Run not found: \(accession)")
            }

            if globalOptions.outputFormat == .json {
                let result = SRARunJSON(
                    accession: run.accession,
                    organism: run.organism,
                    platform: run.platform,
                    libraryStrategy: run.libraryStrategy,
                    libraryLayout: run.libraryLayout,
                    spots: run.spots,
                    bases: run.bases,
                    size: run.size
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            } else {
                print(formatter.header("SRA Run Information"))
                print(formatter.keyValueTable([
                    ("Accession", run.accession),
                    ("Experiment", run.experiment ?? "Unknown"),
                    ("Study", run.study ?? "Unknown"),
                    ("BioProject", run.bioproject ?? "Unknown"),
                    ("BioSample", run.biosample ?? "Unknown"),
                    ("Organism", run.organism ?? "Unknown"),
                    ("Platform", run.platform ?? "Unknown"),
                    ("Strategy", run.libraryStrategy ?? "Unknown"),
                    ("Source", run.librarySource ?? "Unknown"),
                    ("Layout", run.libraryLayout ?? "Unknown"),
                    ("Reads", run.spotsString),
                    ("Bases", run.bases != nil ? "\(run.bases!)" : "Unknown"),
                    ("Size", run.sizeString),
                ]))
            }
        } catch {
            throw CLIError.networkError(reason: "Failed to fetch SRA info: \(error.localizedDescription)")
        }
    }
}
