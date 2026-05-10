// FetchCommand.swift - Remote database fetch command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

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
            GenomeSubcommand.self,
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
              lungfish fetch ncbi MN908947.3 --fetch-format gff3 --save-to MN908947.3.gff3
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
        help: "Fetch format: genbank, fasta, gff3, xml (default: genbank)"
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

    @Flag(
        name: .customLong("no-retry"),
        help: "Do not retry HTTP 429 rate-limit responses"
    )
    var noRetry: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)

        if !globalOptions.quiet {
            print(formatter.info("Fetching \(accessions.count) accession(s) from NCBI \(database)..."))
        }

        // Create NCBI service
        let resolvedAPIKey = Self.resolvedAPIKey(
            explicitAPIKey: apiKey,
            environment: ProcessInfo.processInfo.environment
        )
        let service = NCBIService(
            apiKey: resolvedAPIKey,
            retryPolicy: noRetry ? .disabled : .rateLimitDefaults
        )

        // Map string database to NCBIDatabase enum
        guard let dbEnum = NCBIDatabase(rawValue: database) else {
            throw CLIError.unsupportedFormat(format: "Unknown database: \(database). Use: nucleotide, protein, genome")
        }

        let ncbiFormat = try Self.ncbiFormat(for: fetchFormat)

        var fetchedRecords: [(accession: String, content: String)] = []

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
                let resolvedContent = ncbiFormat == .gff3
                    ? Self.normalizedGFF3Content(content, accession: accession)
                    : content
                if ncbiFormat == .gff3 && Self.gff3FeatureCount(in: resolvedContent) == 0 && !globalOptions.quiet {
                    Self.writeLineToStandardError(
                        formatter.warning("NCBI returned no GFF3 feature rows for \(accession); the file contains only comments/directives.")
                    )
                }
                fetchedRecords.append((accession: accession, content: resolvedContent))
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.networkError(reason: "Failed to fetch \(accession): \(error.localizedDescription)")
            }
        }
        let allContent = Self.combinedContent(for: fetchedRecords, format: ncbiFormat)
        let retryEvents = await service.retryEventsSnapshot()

        // Write output
        if let outputPath = saveTo {
            do {
                try writeNCBIFetchOutputWithProvenance(
                    content: allContent,
                    outputURL: URL(fileURLWithPath: outputPath),
                    startedAt: startedAt,
                    completedAt: Date(),
                    retryEvents: retryEvents
                )
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

    static func provenanceSidecarURL(for outputURL: URL) -> URL {
        outputURL.appendingPathExtension("lungfish-provenance.json")
    }

    func writeNCBIFetchOutputWithProvenance(
        content: String,
        outputURL: URL,
        startedAt: Date,
        completedAt: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retryEvents: [NCBIRetryEvent] = []
    ) throws {
        let fm = FileManager.default
        let outputDirectoryURL = outputURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let tempOutputURL = outputDirectoryURL
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(token).tmp")
        let tempProvenanceURL = outputDirectoryURL
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(token).lungfish-provenance.tmp")
        let finalProvenanceURL = Self.provenanceSidecarURL(for: outputURL)
        let backupOutputURL = outputDirectoryURL
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(token).backup")
        let backupProvenanceURL = outputDirectoryURL
            .appendingPathComponent(".\(finalProvenanceURL.lastPathComponent).\(token).backup")
        var outputBackedUp = false
        var provenanceBackedUp = false
        var outputInstalled = false

        do {
            try content.write(to: tempOutputURL, atomically: true, encoding: .utf8)
            let tempRecord = ProvenanceRecorder.fileRecord(
                url: tempOutputURL,
                format: fileFormat(forFetchFormat: fetchFormat),
                role: .output
            )
            let finalOutputRecord = FileRecord(
                path: outputURL.standardizedFileURL.path,
                sha256: tempRecord.sha256,
                sizeBytes: tempRecord.sizeBytes,
                format: tempRecord.format,
                role: tempRecord.role
            )
            try ncbiFetchProvenanceData(
                outputURL: outputURL,
                outputRecord: finalOutputRecord,
                startedAt: startedAt,
                completedAt: completedAt,
                environment: environment,
                retryEvents: retryEvents
            ).write(to: tempProvenanceURL, options: .atomic)

            if fm.fileExists(atPath: outputURL.path) {
                try fm.moveItem(at: outputURL, to: backupOutputURL)
                outputBackedUp = true
            }
            if fm.fileExists(atPath: finalProvenanceURL.path) {
                try fm.moveItem(at: finalProvenanceURL, to: backupProvenanceURL)
                provenanceBackedUp = true
            }

            try fm.moveItem(at: tempOutputURL, to: outputURL)
            outputInstalled = true
            try fm.moveItem(at: tempProvenanceURL, to: finalProvenanceURL)

            try? fm.removeItem(at: backupOutputURL)
            try? fm.removeItem(at: backupProvenanceURL)
        } catch {
            if outputInstalled {
                try? fm.removeItem(at: outputURL)
            }
            if outputBackedUp {
                try? fm.moveItem(at: backupOutputURL, to: outputURL)
            }
            if provenanceBackedUp {
                try? fm.moveItem(at: backupProvenanceURL, to: finalProvenanceURL)
            }
            try? fm.removeItem(at: tempOutputURL)
            try? fm.removeItem(at: tempProvenanceURL)
            throw error
        }
    }

    func writeNCBIFetchProvenance(
        outputURL: URL,
        startedAt: Date,
        completedAt: Date,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retryEvents: [NCBIRetryEvent] = []
    ) throws {
        let outputRecord = ProvenanceRecorder.fileRecord(
            url: outputURL,
            format: fileFormat(forFetchFormat: fetchFormat),
            role: .output
        )
        try ncbiFetchProvenanceData(
            outputURL: outputURL,
            outputRecord: outputRecord,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: environment,
            retryEvents: retryEvents
        ).write(
            to: Self.provenanceSidecarURL(for: outputURL),
            options: .atomic
        )
    }

    private func ncbiFetchProvenanceData(
        outputURL: URL,
        outputRecord: FileRecord,
        startedAt: Date,
        completedAt: Date,
        environment: [String: String],
        retryEvents: [NCBIRetryEvent]
    ) throws -> Data {
        let step = StepExecution(
            toolName: "ncbi-efetch",
            toolVersion: "NCBI E-utilities API",
            command: ncbiFetchCommand(outputPath: outputURL.path),
            inputs: ncbiInputRecords(),
            outputs: [outputRecord],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startTime: startedAt,
            endTime: completedAt
        )
        let run = WorkflowRun(
            name: "ncbi-sequence-fetch",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
            hostOS: WorkflowRun.currentHostOS,
            steps: [step],
            parameters: [
                "accessions": .array(accessions.map { .string($0) }),
                "database": .string(database),
                "fetchFormat": .string(fetchFormat),
                "resolvedFetchFormat": .string(Self.resolvedFetchFormatName(for: fetchFormat)),
                "saveTo": .string(outputURL.standardizedFileURL.path),
                "apiKeyProvided": .boolean(Self.apiKeyProvided(explicitAPIKey: apiKey, environment: environment)),
                "retryEnabled": .boolean(!noRetry),
                "retryCount": .integer(retryEvents.count),
                "retryEvents": .array(Self.retryEventParameterValues(retryEvents)),
                "outputFormat": .string(globalOptions.outputFormat.rawValue),
                "quiet": .boolean(globalOptions.quiet),
                "endpoint": .string("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"),
                "containerRuntime": .string("none"),
                "condaEnvironment": .string("none")
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(run)
    }

    private func ncbiFetchCommand(outputPath: String) -> [String] {
        var command = ["lungfish", "fetch", "ncbi"] + accessions + [
            "--db", database,
            "--fetch-format", fetchFormat,
            "--save-to", outputPath,
            "--format", globalOptions.outputFormat.rawValue
        ]
        if apiKey != nil {
            command += ["--api-key", "<redacted>"]
        }
        if noRetry {
            command.append("--no-retry")
        }
        if globalOptions.quiet {
            command.append("--quiet")
        }
        return command
    }

    static func resolvedAPIKey(explicitAPIKey: String?, environment: [String: String]) -> String? {
        if let explicitAPIKey, !explicitAPIKey.isEmpty {
            return explicitAPIKey
        }
        guard let environmentAPIKey = environment["NCBI_API_KEY"],
              !environmentAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return environmentAPIKey
    }

    static func apiKeyProvided(explicitAPIKey: String?, environment: [String: String]) -> Bool {
        resolvedAPIKey(explicitAPIKey: explicitAPIKey, environment: environment) != nil
    }

    static func retryEventParameterValues(_ events: [NCBIRetryEvent]) -> [ParameterValue] {
        events.map { event in
            .dictionary([
                "attempt": .integer(event.attempt),
                "maxRetries": .integer(event.maxRetries),
                "statusCode": .integer(event.statusCode),
                "delaySeconds": .number(event.delaySeconds)
            ])
        }
    }

    private func ncbiInputRecords() -> [FileRecord] {
        let rettype = Self.ncbiRettype(for: fetchFormat)
        return accessions.map { accession in
            FileRecord(
                path: "ncbi://\(database)/\(accession)?rettype=\(rettype)",
                format: fileFormat(forFetchFormat: fetchFormat),
                role: .input
            )
        }
    }

    static func ncbiRettype(for fetchFormat: String) -> String {
        guard let format = try? ncbiFormat(for: fetchFormat) else {
            return fetchFormat
        }
        switch format {
        case .fasta:
            return "fasta"
        case .genbank, .genbankWithParts:
            return "gb"
        case .gff3:
            return "gff3"
        case .xml:
            return "native"
        }
    }

    private func fileFormat(forFetchFormat fetchFormat: String) -> FileFormat {
        switch fetchFormat.lowercased() {
        case "fasta", "fa":
            return .fasta
        case "genbank", "gb":
            return .genBank
        case "gff", "gff3":
            return .gff3
        default:
            return .unknown
        }
    }

    static func ncbiFormat(for fetchFormat: String) throws -> NCBIFormat {
        switch fetchFormat.lowercased() {
        case "genbank", "gb":
            return .genbank
        case "fasta", "fa":
            return .fasta
        case "gff", "gff3":
            return .gff3
        case "xml":
            return .xml
        default:
            throw CLIError.unsupportedFormat(format: fetchFormat)
        }
    }

    static func resolvedFetchFormatName(for fetchFormat: String) -> String {
        guard let format = try? ncbiFormat(for: fetchFormat) else {
            return fetchFormat
        }
        switch format {
        case .fasta:
            return "fasta"
        case .genbank, .genbankWithParts:
            return "genbank"
        case .gff3:
            return "gff3"
        case .xml:
            return "xml"
        }
    }

    static func gff3FeatureCount(in content: String) -> Int {
        content
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
            .count
    }

    static func normalizedGFF3Content(_ content: String, accession: String) -> String {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "##gff-version 3\n"
        }
        return content.hasSuffix("\n") ? content : content + "\n"
    }

    static func combinedContent(
        for records: [(accession: String, content: String)],
        format: NCBIFormat
    ) -> String {
        guard format == .gff3, records.count > 1 else {
            return records.map { $0.content }.joined()
        }
        return records
            .map { record in
                var section = "# lungfish fetch ncbi accession: \(record.accession)\n"
                section += record.content
                if !section.hasSuffix("\n") {
                    section += "\n"
                }
                return section
            }
            .joined(separator: "###\n")
    }

    private static func writeLineToStandardError(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else {
            return
        }
        FileHandle.standardError.write(data)
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
        let startedAt = Date()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let trace = SRADownloadTraceCapture(selectedStrategy: useToolkit ? "sra-toolkit" : "ena-direct")

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
                } trace: { step in
                    trace.recordStep(step)
                }
            } else {
                let quiet = globalOptions.quiet
                let useColors = globalOptions.useColors
                files = try await service.downloadFASTQWithFallback(
                    accession: accession,
                    outputDir: outputURL,
                    progress: { progress in
                        if !quiet {
                            let formatter = TerminalFormatter(useColors: useColors)
                            print(formatter.info("Download progress: \(Int(progress * 100))%"))
                        }
                    },
                    onFallback: { message in
                        trace.recordFallback(message)
                        if !quiet {
                            let formatter = TerminalFormatter(useColors: useColors)
                            print(formatter.info(message))
                        }
                    },
                    trace: { step in
                        trace.recordStep(step)
                    }
                )
            }

            try writeSRADownloadProvenance(
                files: files,
                outputURL: outputURL,
                trace: trace,
                startedAt: startedAt,
                completedAt: Date()
            )

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

    private func sraDownloadCommand() -> [String] {
        var command = [
            "lungfish",
            "fetch",
            "sra",
            "download",
            accession,
            "--output-dir", outputDir,
            "--format", globalOptions.outputFormat.rawValue
        ]
        if useToolkit {
            command.append("--use-toolkit")
        }
        if globalOptions.quiet {
            command.append("--quiet")
        }
        return command
    }

    private func sraDownloadProvenanceParameters(
        trace: SRADownloadTraceCapture
    ) -> [String: ParameterValue] {
        [
            "accession": .string(accession),
            "outputDir": .string(URL(fileURLWithPath: outputDir).standardizedFileURL.path),
            "requestedStrategy": .string(useToolkit ? "sra-toolkit" : "ena-direct"),
            "selectedStrategy": .string(trace.selectedStrategy),
            "fallbackMessage": trace.fallbackMessage.map { .string($0) } ?? .null,
            "sourceInputs": .array(trace.sourceInputs.map { .string($0) }),
            "executedStepCount": .integer(trace.steps.count),
            "outputFormat": .string(globalOptions.outputFormat.rawValue),
            "quiet": .boolean(globalOptions.quiet),
            "containerRuntime": .string("none"),
            "condaEnvironment": .string("managed sra-tools when --use-toolkit or fallback is selected")
        ]
    }

    private func writeSRADownloadProvenance(
        files: [URL],
        outputURL: URL,
        trace: SRADownloadTraceCapture,
        startedAt: Date,
        completedAt: Date
    ) throws {
        var steps = trace.steps.map { step in
            StepExecution(
                toolName: step.toolName,
                toolVersion: sraStepToolVersion(step.toolVersion),
                command: step.command,
                inputs: step.inputs.map { input in
                    FileRecord(path: input, format: detectSRAInputFormat(input), role: .input)
                },
                outputs: step.outputs.map {
                    ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output)
                },
                exitCode: step.exitCode,
                wallTime: step.wallTime,
                stderr: step.stderr,
                startTime: step.startedAt,
                endTime: step.completedAt
            )
        }
        steps.append(
            StepExecution(
                toolName: "lungfish-cli",
                toolVersion: LungfishCLI.configuration.version,
                command: sraDownloadCommand(),
                inputs: trace.sourceInputs.map { input in
                    FileRecord(path: input, format: detectSRAInputFormat(input), role: .input)
                },
                outputs: files.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
                exitCode: 0,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: trace.fallbackMessage,
                dependsOn: steps.last.map { [$0.id] } ?? [],
                startTime: startedAt,
                endTime: completedAt
            )
        )

        let run = WorkflowRun(
            name: "sra-fastq-download",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
            hostOS: WorkflowRun.currentHostOS,
            steps: steps,
            parameters: sraDownloadProvenanceParameters(trace: trace)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let provenanceURL = outputURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
    }

    private func detectSRAInputFormat(_ input: String) -> FileFormat? {
        let lowercase = input.lowercased()
        if lowercase.hasSuffix(".fastq") || lowercase.hasSuffix(".fq")
            || lowercase.hasSuffix(".fastq.gz") || lowercase.hasSuffix(".fq.gz") {
            return .fastq
        }
        if lowercase.hasSuffix(".sra") {
            return .unknown
        }
        return nil
    }

    private func sraStepToolVersion(_ version: String) -> String {
        guard version == "sra-tools",
              let lockVersion = try? ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version else {
            return version
        }
        return "sra-tools \(lockVersion)"
    }
}

private final class SRADownloadTraceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _selectedStrategy: String
    private var _fallbackMessage: String?
    private var _steps: [SRAService.FASTQDownloadStepTrace] = []

    init(selectedStrategy: String) {
        self._selectedStrategy = selectedStrategy
    }

    var selectedStrategy: String {
        lock.lock()
        defer { lock.unlock() }
        return _selectedStrategy
    }

    var fallbackMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _fallbackMessage
    }

    var steps: [SRAService.FASTQDownloadStepTrace] {
        lock.lock()
        defer { lock.unlock() }
        return _steps
    }

    var sourceInputs: [String] {
        lock.lock()
        defer { lock.unlock() }
        let inputs = _steps.flatMap(\.inputs)
        return Array(Set(inputs)).sorted()
    }

    func recordFallback(_ message: String) {
        lock.lock()
        _selectedStrategy = "sra-toolkit-fallback"
        _fallbackMessage = message
        lock.unlock()
    }

    func recordStep(_ step: SRAService.FASTQDownloadStepTrace) {
        lock.lock()
        _steps.append(step)
        lock.unlock()
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
                    length: fasta.split(separator: "\n").filter { !$0.hasPrefix(">") }.joined().count
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

// MARK: - Genome Subcommand

/// Download genome assemblies from NCBI and create indexed bundles
struct GenomeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genome",
        abstract: "Download genome assemblies from NCBI and create indexed bundles",
        discussion: """
            Downloads a genome assembly from NCBI Datasets, including the FASTA sequence
            and GFF3 annotations, then creates a .lungfishref bundle with proper indices.

            The bundle contains:
            - Compressed, indexed FASTA (bgzip + samtools faidx)
            - SQLite annotation database (converted from GFF3)
            - Manifest with metadata

            Examples:
              lungfish fetch genome GCF_003047895.1 --output-dir ./genomes
              lungfish fetch genome GCF_000001405.40 --name "Human GRCh38" --output-dir ./
              lungfish fetch genome GCF_003047895.1 --fasta-only --output-dir ./
            """
    )

    @Argument(help: "Assembly accession (e.g., GCF_003047895.1, GCA_000001405.29)")
    var accession: String

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for the bundle (default: current directory)"
    )
    var outputDir: String = "."

    @Option(
        name: .long,
        help: "Bundle name (default: derived from assembly)"
    )
    var name: String?

    @Flag(
        name: .customLong("fasta-only"),
        help: "Download only the FASTA sequence (no annotations, no bundle)"
    )
    var fastaOnly: Bool = false

    @Flag(
        name: .customLong("no-bundle"),
        help: "Download files but don't create a .lungfishref bundle"
    )
    var noBundle: Bool = false

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let fileManager = FileManager.default

        // Create output directory if needed
        let outputURL = URL(fileURLWithPath: outputDir)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        if !globalOptions.quiet {
            print(formatter.header("Downloading Genome Assembly"))
            print("Accession: \(accession)")
            print("Output: \(outputURL.path)")
            print("")
        }

        // Step 1: Search for the assembly to get metadata
        if !globalOptions.quiet {
            print(formatter.info("Searching for assembly \(accession)..."))
        }

        let ncbiService = NCBIService(apiKey: apiKey)

        // Search the assembly database
        let searchResult = try await ncbiService.searchGenome(term: accession, retmax: 1)

        guard !searchResult.ids.isEmpty else {
            throw CLIError.networkError(reason: "Assembly not found: \(accession)")
        }

        // Get assembly summary
        let summaries = try await ncbiService.assemblyEsummary(ids: searchResult.ids)

        guard let summary = summaries.first else {
            throw CLIError.networkError(reason: "Could not retrieve assembly metadata for \(accession)")
        }

        let assemblyAccession = summary.assemblyAccession ?? accession
        let organism = summary.organism ?? summary.speciesName ?? "Unknown"
        let bundleName = name ?? "\(organism.replacingOccurrences(of: " ", with: "_"))_\(assemblyAccession)"

        if !globalOptions.quiet {
            print(formatter.success("Found: \(organism)"))
            print("  Assembly: \(assemblyAccession)")
            if let coverage = summary.coverage {
                print("  Coverage: \(coverage)")
            }
            print("")
        }

        // Step 2: Get download URLs and download files
        if !globalOptions.quiet {
            print(formatter.info("Getting download URLs..."))
        }

        let genomeFileInfo = try await ncbiService.getGenomeFileInfo(for: summary)

        // Create a temp directory for downloads
        let tempDir = try ProjectTempDirectory.createFromContext(prefix: ".lungfish-temp-", contextURL: outputURL)

        defer {
            // Clean up temp directory
            try? fileManager.removeItem(at: tempDir)
        }

        // Download FASTA
        if !globalOptions.quiet {
            let sizeStr = genomeFileInfo.estimatedSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
            print(formatter.info("Downloading FASTA (\(sizeStr))..."))
        }

        let fastaGzPath = tempDir.appendingPathComponent(genomeFileInfo.filename)
        _ = try await ncbiService.downloadGenomeFile(genomeFileInfo, to: fastaGzPath) { downloaded, total in
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                let downloadedStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                if let total = total {
                    let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    let percent = Int(Double(downloaded) / Double(total) * 100)
                    print("\r  \(downloadedStr) / \(totalStr) (\(percent)%)", terminator: "")
                } else {
                    print("\r  \(downloadedStr)", terminator: "")
                }
                fflush(stdout)
            }
        }

        if !globalOptions.quiet {
            print("") // newline after progress
            print(formatter.success("FASTA downloaded"))
        }

        // Download GFF3 annotations (if not fasta-only)
        var gffPath: URL?
        if !fastaOnly {
            if !globalOptions.quiet {
                print(formatter.info("Downloading annotations (GFF3)..."))
            }

            // Construct GFF3 URL from FTP path
            if let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank {
                let pathComponents = ftpPath.components(separatedBy: "/")
                if let assemblyDirName = pathComponents.last, !assemblyDirName.isEmpty {
                    let gffFilename = "\(assemblyDirName)_genomic.gff.gz"
                    var httpPath = ftpPath
                    if httpPath.hasPrefix("ftp://") {
                        httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
                    } else if !httpPath.hasPrefix("https://") && !httpPath.hasPrefix("http://") {
                        httpPath = "https://\(httpPath)"
                    }

                    if let gffURL = URL(string: "\(httpPath)/\(gffFilename)") {
                        let downloadedGffPath = tempDir.appendingPathComponent(gffFilename)

                        do {
                            let (tempURL, response) = try await URLSession.shared.download(from: gffURL)
                            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                                try fileManager.moveItem(at: tempURL, to: downloadedGffPath)
                                gffPath = downloadedGffPath
                                if !globalOptions.quiet {
                                    print(formatter.success("Annotations downloaded"))
                                }
                            } else {
                                if !globalOptions.quiet {
                                    print(formatter.warning("Annotations not available for this assembly"))
                                }
                            }
                        } catch {
                            if !globalOptions.quiet {
                                print(formatter.warning("Could not download annotations: \(error.localizedDescription)"))
                            }
                        }
                    }
                }
            }
        }

        // If fasta-only or no-bundle, just decompress and save
        if fastaOnly || noBundle {
            let finalFastaPath = outputURL.appendingPathComponent("\(bundleName).fna.gz")
            try fileManager.copyItem(at: fastaGzPath, to: finalFastaPath)

            if let gff = gffPath {
                let finalGffPath = outputURL.appendingPathComponent("\(bundleName).gff.gz")
                try fileManager.copyItem(at: gff, to: finalGffPath)
            }

            if !globalOptions.quiet {
                print("")
                print(formatter.success("Files saved:"))
                print("  FASTA: \(outputURL.appendingPathComponent("\(bundleName).fna.gz").path)")
                if gffPath != nil {
                    print("  GFF3: \(outputURL.appendingPathComponent("\(bundleName).gff.gz").path)")
                }
            }

            if globalOptions.outputFormat == .json {
                let result = GenomeDownloadResult(
                    accession: assemblyAccession,
                    organism: organism,
                    fastaPath: outputURL.appendingPathComponent("\(bundleName).fna.gz").path,
                    gffPath: gffPath != nil ? outputURL.appendingPathComponent("\(bundleName).gff.gz").path : nil,
                    bundlePath: nil
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            }
            return
        }

        // Step 3: Create the .lungfishref bundle with proper indices
        if !globalOptions.quiet {
            print("")
            print(formatter.header("Creating Indexed Bundle"))
        }

        // Use NativeBundleBuilder to create the bundle
        let builder = await NativeBundleBuilder()

        // Check for required tools
        if let missingInfo = await builder.checkRequiredTools() {
            if !globalOptions.quiet {
                print(formatter.warning("Native bioinformatics tools not available."))
                print(formatter.warning("Missing: \(missingInfo.missingTools.map { $0.rawValue }.joined(separator: ", "))"))
                print(formatter.info("Creating basic bundle without optimized indices..."))
            }
        }

        // Decompress FASTA for bundle builder (it will re-compress with bgzip)
        let uncompressedFastaPath = tempDir.appendingPathComponent("sequence.fna")
        let decompressProcess = Process()
        decompressProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        decompressProcess.arguments = ["-c", fastaGzPath.path]
        let outputPipe = Pipe()
        decompressProcess.standardOutput = outputPipe
        try decompressProcess.run()

        let fastaData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        decompressProcess.waitUntilExit()
        try fastaData.write(to: uncompressedFastaPath)

        // Prepare annotation inputs
        var annotationInputs: [AnnotationInput] = []
        if let gff = gffPath {
            // Pass GFF3 directly; NativeBundleBuilder handles .gff/.gff3 and .gz variants.
            annotationInputs.append(AnnotationInput(url: gff, name: "genes"))
        }

        // Create build configuration
        let config = BuildConfiguration(
            name: name ?? organism,
            identifier: "com.ncbi.\(assemblyAccession.lowercased().replacingOccurrences(of: ".", with: "-"))",
            fastaURL: uncompressedFastaPath,
            annotationFiles: annotationInputs,
            variantFiles: [],
            signalFiles: [],
            outputDirectory: outputURL,
            source: SourceInfo(
                organism: organism,
                commonName: nil,
                taxonomyId: summary.taxid,
                assembly: assemblyAccession,
                assemblyAccession: assemblyAccession,
                database: "NCBI",
                sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/datasets/genome/\(assemblyAccession)/"),
                downloadDate: Date(),
                notes: nil
            ),
            compressFASTA: true
        )

        // Build the bundle
        let bundleURL = try await builder.build(configuration: config) { step, progress, message in
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                let progressPercent = Int(progress * 100)
                print("\r  [\(progressPercent)%] \(message)", terminator: "")
                fflush(stdout)
            }
        }

        if !globalOptions.quiet {
            print("") // newline after progress
            print("")
            print(formatter.success("Bundle created successfully!"))
            print("")
            print("Bundle location: \(bundleURL.path)")
            print("")
            print("Contents:")
            print("  - Indexed FASTA sequence (bgzip + faidx)")
            if !annotationInputs.isEmpty {
                print("  - SQLite annotation database")
            }
            print("  - Manifest with metadata")
        }

        if globalOptions.outputFormat == .json {
            let result = GenomeDownloadResult(
                accession: assemblyAccession,
                organism: organism,
                fastaPath: nil,
                gffPath: nil,
                bundlePath: bundleURL.path
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }
}

/// JSON output for genome download
struct GenomeDownloadResult: Codable {
    let accession: String
    let organism: String
    let fastaPath: String?
    let gffPath: String?
    let bundlePath: String?
}
