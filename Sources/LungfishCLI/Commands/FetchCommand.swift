// FetchCommand.swift - Remote database fetch command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore

/// Fetch sequences from remote databases
struct FetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fetch",
        abstract: "Fetch sequences from remote databases",
        subcommands: [
            NCBISubcommand.self,
            SearchSubcommand.self,
        ],
        defaultSubcommand: NCBISubcommand.self
    )
}

// MARK: - NCBI Subcommand

/// Fetch from NCBI GenBank
struct NCBISubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ncbi",
        abstract: "Fetch sequence from NCBI by accession",
        discussion: """
            Download sequences from NCBI GenBank/RefSeq databases.

            Examples:
              lungfish fetch ncbi NC_002549 --save-to ebola.gb
              lungfish fetch ncbi NC_002549 --fetch-format fasta --save-to ebola.fa
              lungfish fetch ncbi MN908947 NM_000546 --save-to sequences.gb
            """
    )

    @Argument(help: "Accession number(s)")
    var accessions: [String]

    @Option(
        name: .customLong("db"),
        help: "Database: nucleotide, protein (default: nucleotide)"
    )
    var database: String = "nucleotide"

    @Option(
        name: .customLong("fetch-format"),
        help: "Fetch format: genbank, fasta (default: genbank)"
    )
    var fetchFormat: String = "genbank"

    @Option(
        name: .customLong("save-to"),
        help: "Output file path"
    )
    var saveTo: String?

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching \(accessions.count) accession(s) from NCBI \(database)..."))
        }

        // Create NCBI service
        let service = NCBIService(apiKey: apiKey)

        // Map string database to NCBIDatabase enum
        guard let dbEnum = NCBIDatabase(rawValue: database) else {
            throw CLIError.unsupportedFormat(format: "Unknown database: \(database). Use: nucleotide, protein, genome")
        }

        // Map format string to NCBIFormat
        let ncbiFormat: NCBIFormat
        switch fetchFormat.lowercased() {
        case "genbank", "gb":
            ncbiFormat = .genbank
        case "fasta", "fa":
            ncbiFormat = .fasta
        case "xml":
            ncbiFormat = .xml
        default:
            throw CLIError.unsupportedFormat(format: fetchFormat)
        }

        var allContent = ""

        for (index, accession) in accessions.enumerated() {
            if !globalOptions.quiet && accessions.count > 1 {
                print(formatter.info("[\(index + 1)/\(accessions.count)] Fetching \(accession)..."))
            }

            do {
                let data = try await service.efetch(
                    database: dbEnum,
                    ids: [accession],
                    format: ncbiFormat
                )
                guard let content = String(data: data, encoding: .utf8) else {
                    throw CLIError.networkError(reason: "Invalid encoding in response for \(accession)")
                }
                allContent += content
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.networkError(reason: "Failed to fetch \(accession): \(error.localizedDescription)")
            }
        }

        // Write output
        if let outputPath = saveTo {
            do {
                try allContent.write(toFile: outputPath, atomically: true, encoding: .utf8)
                if !globalOptions.quiet {
                    print(formatter.success("Saved to \(outputPath)"))
                }
            } catch {
                throw CLIError.outputWriteFailed(path: outputPath, reason: error.localizedDescription)
            }
        } else {
            // Write to stdout
            print(allContent)
        }

        if globalOptions.outputFormat == .json {
            let result = FetchResult(
                accessions: accessions,
                database: database,
                format: fetchFormat,
                outputFile: saveTo
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }
}

/// Fetch result for JSON output
struct FetchResult: Codable {
    let accessions: [String]
    let database: String
    let format: String
    let outputFile: String?
}

// MARK: - Search Subcommand

/// Search NCBI databases
struct SearchSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search NCBI databases",
        discussion: """
            Search NCBI databases and list matching accessions.

            Examples:
              lungfish fetch search "Ebola virus" --db nucleotide --limit 10
              lungfish fetch search "BRCA1[Gene]" --db nucleotide --organism human
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

/// Search result for JSON output
struct SearchResult: Codable {
    let query: String
    let database: String
    let ids: [String]
}
