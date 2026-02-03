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
            SRASubcommand.self,
            ENASubcommand.self,
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

// MARK: - SRA Subcommand

/// Search and download from SRA (Sequence Read Archive)
struct SRASubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sra",
        abstract: "Search and download from SRA (Sequence Read Archive)",
        discussion: """
            Search for sequencing reads in the NCBI Sequence Read Archive and
            download FASTQ files. Downloads use ENA mirrors for direct HTTP access
            (no SRA Toolkit required).

            Examples:
              lungfish fetch sra search "SARS-CoV-2 Illumina" --limit 10
              lungfish fetch sra download SRR11140748 --output-dir ./fastq
              lungfish fetch sra info SRR11140748
            """,
        subcommands: [
            SRASearchSubcommand.self,
            SRADownloadSubcommand.self,
            SRAInfoSubcommand.self,
        ],
        defaultSubcommand: SRASearchSubcommand.self
    )
}

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

/// Download FASTQ from SRA via ENA
struct SRADownloadSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download",
        abstract: "Download FASTQ files from SRA"
    )

    @Argument(help: "SRA run accession (e.g., SRR11140748)")
    var accession: String

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for FASTQ files (default: current directory)"
    )
    var outputDir: String = "."

    @Flag(
        name: .customLong("use-toolkit"),
        help: "Use SRA Toolkit instead of ENA (requires prefetch/fasterq-dump)"
    )
    var useToolkit: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        let outputURL = URL(fileURLWithPath: outputDir)

        // Create output directory if needed
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        if !globalOptions.quiet {
            print(formatter.info("Downloading FASTQ for \(accession)..."))
            if useToolkit {
                print(formatter.info("Using SRA Toolkit (prefetch + fasterq-dump)"))
            } else {
                print(formatter.info("Using ENA direct download"))
            }
        }

        let service = SRAService()

        do {
            let files: [URL]

            if useToolkit {
                files = try await service.downloadFASTQ(
                    accession: accession,
                    outputDir: outputURL
                ) { progress in
                    if !globalOptions.quiet {
                        print(formatter.info("Download progress: \(Int(progress * 100))%"))
                    }
                }
            } else {
                files = try await service.downloadFASTQFromENA(
                    accession: accession,
                    outputDir: outputURL
                ) { progress in
                    if !globalOptions.quiet {
                        print(formatter.info("Download progress: \(Int(progress * 100))%"))
                    }
                }
            }

            if globalOptions.outputFormat == .json {
                let result = SRADownloadResult(
                    accession: accession,
                    files: files.map { $0.path },
                    outputDir: outputDir
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            } else {
                print(formatter.success("Downloaded \(files.count) FASTQ file(s):"))
                for file in files {
                    print("  - \(file.lastPathComponent)")
                }
            }
        } catch let error as SRAError {
            throw CLIError.networkError(reason: error.localizedDescription)
        } catch {
            throw CLIError.networkError(reason: "Download failed: \(error.localizedDescription)")
        }
    }
}

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

/// JSON output for SRA search
struct SRASearchJSONResult: Codable {
    let query: String
    let totalCount: Int
    let runs: [SRARunJSON]
}

/// JSON output for SRA run
struct SRARunJSON: Codable {
    let accession: String
    let organism: String?
    let platform: String?
    let libraryStrategy: String?
    let libraryLayout: String?
    let spots: Int?
    let bases: Int?
    let size: Int?
}

/// JSON output for SRA download
struct SRADownloadResult: Codable {
    let accession: String
    let files: [String]
    let outputDir: String
}

// MARK: - ENA Subcommand

/// Search and download from ENA (European Nucleotide Archive)
struct ENASubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ena",
        abstract: "Search and download from ENA (European Nucleotide Archive)",
        discussion: """
            Search for sequences and reads in the European Nucleotide Archive.
            ENA provides direct FASTQ download URLs without requiring the SRA Toolkit.

            Examples:
              lungfish fetch ena search "Ebola virus" --limit 10
              lungfish fetch ena reads SRR11140748
              lungfish fetch ena fasta NC_002549
            """,
        subcommands: [
            ENASearchSubcommand.self,
            ENAReadsSubcommand.self,
            ENAFastaSubcommand.self,
        ],
        defaultSubcommand: ENASearchSubcommand.self
    )
}

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

/// Get read data with FASTQ URLs from ENA
struct ENAReadsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reads",
        abstract: "Get read/SRA data with FASTQ download URLs"
    )

    @Argument(help: "Run accession or study ID (e.g., SRR11140748, PRJNA123456)")
    var accession: String

    @Option(
        name: .customLong("limit"),
        help: "Maximum results (default: 20)"
    )
    var limit: Int = 20

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching read info for \(accession) from ENA..."))
        }

        let service = ENAService()

        do {
            let records = try await service.searchReads(term: accession, limit: limit)

            if globalOptions.outputFormat == .json {
                let jsonResults = ENAReadsJSONResult(
                    accession: accession,
                    records: records.map { record in
                        ENAReadJSON(
                            runAccession: record.runAccession,
                            studyAccession: record.studyAccession,
                            platform: record.instrumentPlatform,
                            libraryStrategy: record.libraryStrategy,
                            libraryLayout: record.libraryLayout,
                            readCount: record.readCount,
                            fileSize: record.formattedFileSize,
                            fastqURLs: record.fastqHTTPURLs.map { $0.absoluteString }
                        )
                    }
                )
                let handler = JSONOutputHandler()
                handler.writeData(jsonResults, label: nil)
            } else {
                print(formatter.header("ENA Read Data"))

                if records.isEmpty {
                    print(formatter.warning("No read data found for \(accession)"))
                } else {
                    print("Found \(records.count) run(s)\n")

                    for record in records {
                        print(formatter.keyValueTable([
                            ("Run", record.runAccession),
                            ("Study", record.studyAccession ?? "Unknown"),
                            ("Platform", record.instrumentPlatform ?? "Unknown"),
                            ("Strategy", record.libraryStrategy ?? "Unknown"),
                            ("Layout", record.libraryLayout ?? "Unknown"),
                            ("Reads", record.readCount != nil ? "\(record.readCount!)" : "Unknown"),
                            ("File Size", record.formattedFileSize ?? "Unknown"),
                        ]))

                        let urls = record.fastqHTTPURLs
                        if !urls.isEmpty {
                            print("\n  FASTQ URLs:")
                            for url in urls {
                                print("    \(url.absoluteString)")
                            }
                        }
                        print("")
                    }
                }
            }
        } catch {
            throw CLIError.networkError(reason: "ENA read fetch failed: \(error.localizedDescription)")
        }
    }
}

/// Fetch FASTA from ENA
struct ENAFastaSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fasta",
        abstract: "Fetch sequence in FASTA format from ENA"
    )

    @Argument(help: "Accession number")
    var accession: String

    @Option(
        name: .customLong("save-to"),
        help: "Output file path"
    )
    var saveTo: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching FASTA for \(accession) from ENA..."))
        }

        let service = ENAService()

        do {
            let fasta = try await service.fetchFASTA(accession: accession)

            if let outputPath = saveTo {
                try fasta.write(toFile: outputPath, atomically: true, encoding: .utf8)
                if !globalOptions.quiet {
                    print(formatter.success("Saved to \(outputPath)"))
                }
            } else {
                print(fasta)
            }

            if globalOptions.outputFormat == .json {
                let result = ENAFastaResult(
                    accession: accession,
                    outputFile: saveTo,
                    length: fasta.filter { !$0.isWhitespace && $0 != ">" }.count
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            }
        } catch {
            throw CLIError.networkError(reason: "ENA fetch failed: \(error.localizedDescription)")
        }
    }
}

/// JSON output for ENA search
struct ENASearchJSONResult: Codable {
    let query: String
    let totalCount: Int
    let records: [ENARecordJSON]
}

/// JSON output for ENA record
struct ENARecordJSON: Codable {
    let accession: String
    let title: String
    let organism: String?
    let length: Int?
}

/// JSON output for ENA reads
struct ENAReadsJSONResult: Codable {
    let accession: String
    let records: [ENAReadJSON]
}

/// JSON output for ENA read record
struct ENAReadJSON: Codable {
    let runAccession: String
    let studyAccession: String?
    let platform: String?
    let libraryStrategy: String?
    let libraryLayout: String?
    let readCount: Int?
    let fileSize: String?
    let fastqURLs: [String]
}

/// JSON output for ENA FASTA fetch
struct ENAFastaResult: Codable {
    let accession: String
    let outputFile: String?
    let length: Int
}
