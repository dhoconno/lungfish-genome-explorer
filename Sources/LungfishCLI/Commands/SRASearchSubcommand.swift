// SRASearchSubcommand.swift - Search SRA database
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Search SRA database
struct SRASearchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search SRA for sequencing runs"
    )

    @Argument(help: "Search query")
    var query: String

    @Option(
        name: .customLong("limit"),
        help: "Maximum results (default: 20)"
    )
    var limit: Int = 20

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Searching SRA for: \(query)"))
        }

        let service = SRAService(ncbiService: NCBIService(apiKey: apiKey))

        do {
            let searchQuery = SearchQuery(term: query, limit: limit)
            let results = try await service.search(searchQuery)

            if globalOptions.outputFormat == .json {
                let jsonResults = SRASearchJSONResult(
                    query: query,
                    totalCount: results.totalCount,
                    runs: results.runs.map { run in
                        SRARunJSON(
                            accession: run.accession,
                            organism: run.organism,
                            platform: run.platform,
                            libraryStrategy: run.libraryStrategy,
                            libraryLayout: run.libraryLayout,
                            spots: run.spots,
                            bases: run.bases,
                            size: run.size
                        )
                    }
                )
                let handler = JSONOutputHandler()
                handler.writeData(jsonResults, label: nil)
            } else {
                print(formatter.header("SRA Search Results"))
                print("Found \(results.totalCount) runs\n")

                if results.runs.isEmpty {
                    print(formatter.warning("No results found"))
                } else {
                    let headers = ["Accession", "Organism", "Platform", "Strategy", "Layout", "Reads", "Size"]
                    let rows = results.runs.map { run -> [String] in
                        [
                            run.accession,
                            String(run.organism?.prefix(20) ?? "Unknown"),
                            run.platform ?? "Unknown",
                            run.libraryStrategy ?? "Unknown",
                            run.libraryLayout ?? "Unknown",
                            run.spotsString,
                            run.sizeString
                        ]
                    }
                    print(formatter.table(headers: headers, rows: rows))
                }
            }
        } catch {
            throw CLIError.networkError(reason: "SRA search failed: \(error.localizedDescription)")
        }
    }
}
