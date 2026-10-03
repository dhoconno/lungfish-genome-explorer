// ENASearchSubcommand.swift - Search ENA sequences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Search ENA sequences
struct ENASearchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search ENA for sequences"
    )

    @Argument(help: "Search query")
    var query: String

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

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Searching ENA for: \(query)"))
        }

        let service = ENAService()

        do {
            let searchQuery = SearchQuery(term: query, organism: organism, limit: limit)
            let results = try await service.search(searchQuery)

            if globalOptions.outputFormat == .json {
                let jsonResults = ENASearchJSONResult(
                    query: query,
                    totalCount: results.totalCount,
                    records: results.records.map { record in
                        ENARecordJSON(
                            accession: record.accession,
                            title: record.title,
                            organism: record.organism,
                            length: record.length
                        )
                    }
                )
                let handler = JSONOutputHandler()
                handler.writeData(jsonResults, label: nil)
            } else {
                print(formatter.header("ENA Search Results"))
                print("Found \(results.totalCount) sequences\n")

                if results.records.isEmpty {
                    print(formatter.warning("No results found"))
                } else {
                    let headers = ["Accession", "Title", "Organism", "Length"]
                    let rows = results.records.map { record -> [String] in
                        [
                            record.accession,
                            String(record.title.prefix(40)),
                            record.organism ?? "Unknown",
                            record.length != nil ? "\(record.length!)" : "Unknown"
                        ]
                    }
                    print(formatter.table(headers: headers, rows: rows))
                }
            }
        } catch {
            throw CLIError.networkError(reason: "ENA search failed: \(error.localizedDescription)")
        }
    }
}
