// SearchSubcommand.swift - Search NCBI databases
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Search Subcommand

/// Search NCBI databases
struct SearchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search NCBI databases",
        discussion: """
            Search NCBI databases and list matching accessions.

            Examples:
              lungfish-cli fetch search "Ebola virus" --db nucleotide --limit 10
              lungfish-cli fetch search "BRCA1[Gene]" --db nucleotide --organism human
            """
    )

    @Argument(help: "Search query")
    var query: String

    @Option(
        name: .customLong("db"),
        help: "Database: nucleotide, protein, genome (default: nucleotide)"
    )
    var database: String = "nucleotide"

    @Option(
        name: .customLong("limit"),
        help: "Maximum results (default: 20)"
    )
    var limit: Int = 20

    @Option(
        name: .customLong("organism"),
        help: "Filter by organism"
    )
    var organism: String?

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        // Build query with organism filter
        var searchQuery = query
        if let org = organism {
            searchQuery = "(\(query)) AND \(org)[Organism]"
        }

        if !globalOptions.quiet {
            print(formatter.info("Searching NCBI \(database) for: \(searchQuery)"))
        }

        // Map string database to NCBIDatabase enum
        guard let dbEnum = NCBIDatabase(rawValue: database) else {
            throw CLIError.unsupportedFormat(format: "Unknown database: \(database)")
        }

        let service = NCBIService(apiKey: apiKey)

        do {
            let ids = try await service.esearch(
                database: dbEnum,
                term: searchQuery,
                retmax: limit
            )

            if globalOptions.outputFormat == .json {
                let result = SearchResult(query: searchQuery, database: database, ids: ids)
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            } else {
                print(formatter.header("Search Results"))
                print("Found \(ids.count) matches\n")

                for (index, id) in ids.prefix(limit).enumerated() {
                    print("  \(index + 1). \(id)")
                }

                if ids.count > limit {
                    print(formatter.dim("\n  ... and \(ids.count - limit) more"))
                }
            }
        } catch {
            throw CLIError.networkError(reason: "Search failed: \(error.localizedDescription)")
        }
    }
}
