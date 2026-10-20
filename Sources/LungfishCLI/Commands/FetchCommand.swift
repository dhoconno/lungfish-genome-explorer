// FetchCommand.swift - Remote database fetch command
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
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
            PathoplexusSubcommand.self,
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

            With --bundle each accession becomes a .lungfishref bundle in --output-dir,
            built as the app's NCBI browser builds a nucleotide or virus record. The one
            sequence is named by the accession with its version. With --format json the
            command prints CLIEvent lines on standard output and its human text on
            standard error. SIGTERM stops the run, removes the bundle it was building
            and exits 125. Without --bundle, --format json prints the same lines for a run
            that saves its records with --save-to, and refuses to run without --save-to,
            because the records would share standard output with the events. The NCBI key
            comes from --api-key or from the NCBI_API_KEY environment variable.

            Examples:
              lungfish-cli fetch ncbi NC_045512.2 MN908947.3 --bundle --output-dir ./bundles
              lungfish-cli fetch ncbi NC_002549 --save-to ebola.gb
              lungfish-cli fetch ncbi NC_002549 --fetch-format fasta --save-to ebola.fa
              lungfish-cli fetch ncbi MN908947.3 --fetch-format gff3 --save-to MN908947.3.gff3
              lungfish-cli fetch ncbi MN908947 NM_000546 --save-to sequences.gb
            """
    )

    @Argument(help: "Accession number(s)")
    var accessions: [String]

    @Option(
        name: .customLong("db"),
        help: "Database: nucleotide, protein"
    )
    var database: String = "nucleotide"

    @Option(
        name: .customLong("fetch-format"),
        help: "Fetch format: genbank, fasta, gff3, xml"
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

    @Flag(
        name: .customLong("bundle"),
        help: "Build a .lungfishref bundle for each accession instead of saving one file"
    )
    var bundle: Bool = false

    @Option(
        name: .customLong("output-dir"),
        help: "With --bundle, the folder for the bundles (default: current directory)"
    )
    var outputDir: String?

    @Flag(
        name: .customLong("no-gff3"),
        help: "With --bundle, fetch no GFF3 and take the annotations from the GenBank record"
    )
    var noGFF3: Bool = false

    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        if bundle {
            guard saveTo == nil else {
                throw ValidationError("--bundle writes its bundles into --output-dir, so it takes no --save-to.")
            }
            guard database == "nucleotide", fetchFormat == "genbank" else {
                throw ValidationError("--bundle builds from the GenBank record of a nucleotide accession, so it takes no --db or --fetch-format.")
            }
        } else if outputDir != nil || noGFF3 {
            throw ValidationError("--output-dir and --no-gff3 belong to --bundle.")
        }
        // Under --format json standard output holds events, which the records would share.
        if !bundle, globalOptions.outputFormat == .json, saveTo == nil {
            throw ValidationError("--format json prints events on standard output, so the records need --save-to.")
        }
    }

    func run() async throws {
        if bundle {
            try await runBundle()
            return
        }
        let eventsOn = globalOptions.outputFormat == .json
        let reporter = FetchGenomeReporter(
            eventsOn: eventsOn, quiet: globalOptions.quiet, useColors: globalOptions.useColors, subject: "NCBI record")
        reporter.start(accessions: accessions)
        do {
            try await fetchRecords(reporter: reporter)
        } catch {
            // A run that prints events ends with a failed line, and the text of a run that does not
            // goes to the error handler as before.
            guard eventsOn else { throw error }
            var outcome = FetchGenomeOutcome()
            outcome.failures.append(.init(accession: "", message: FetchGenomeRun.message(for: error)))
            try reporter.finish(outcome)
        }
    }

    /// The plain run. It fetches each accession, saves the records in `--save-to` with a record of
    /// the run or prints them, and speaks the lines of `reporter`.
    private func fetchRecords(reporter: FetchGenomeReporter) async throws {
        let runClock = ProvenanceRunClock()
        reporter.info("Fetching \(accessions.count) accession(s) from NCBI \(database)...")

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
            reporter.accessionProgress(accession, index: index, count: accessions.count)
            if accessions.count > 1 {
                reporter.info("[\(index + 1)/\(accessions.count)] Fetching \(accession)...")
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
                if ncbiFormat == .gff3 && Self.gff3FeatureCount(in: resolvedContent) == 0 {
                    reporter.warning("NCBI returned no GFF3 feature rows for \(accession); the file contains only comments/directives.")
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
                    startedAt: runClock.startedAt,
                    completedAt: runClock.now,
                    fetchedRecords: fetchedRecords,
                    retryEvents: retryEvents
                )
                reporter.success("Saved to \(outputPath)")
            } catch {
                throw CLIError.outputWriteFailed(path: outputPath, reason: error.localizedDescription)
            }
            reporter.completeFile(URL(fileURLWithPath: outputPath).standardizedFileURL, records: fetchedRecords.count)
        } else {
            // Write to stdout
            print(allContent)
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
        fetchedRecords: [(accession: String, content: String)]? = nil,
        retryEvents: [NCBIRetryEvent] = []
    ) throws {
        let fm = FileManager.default
        guard !Self.isExistingDirectory(outputURL, fileManager: fm) else {
            throw CocoaError(.fileWriteFileExists)
        }
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
            let provenanceEnvelope = try ncbiFetchProvenanceEnvelope(
                outputURL: outputURL,
                outputRecord: finalOutputRecord,
                startedAt: startedAt,
                completedAt: completedAt,
                environment: environment,
                outputContent: content,
                fetchedRecords: fetchedRecords,
                retryEvents: retryEvents
            )
            try ProvenanceWriter(signingProvider: nil).write(provenanceEnvelope, toSidecar: tempProvenanceURL)

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

    private static func isExistingDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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
        let outputContent = try String(contentsOf: outputURL, encoding: .utf8)
        let provenanceEnvelope = try ncbiFetchProvenanceEnvelope(
            outputURL: outputURL,
            outputRecord: outputRecord,
            startedAt: startedAt,
            completedAt: completedAt,
            environment: environment,
            outputContent: outputContent,
            fetchedRecords: nil,
            retryEvents: retryEvents
        )
        try ProvenanceWriter().write(
            provenanceEnvelope,
            toSidecar: Self.provenanceSidecarURL(for: outputURL)
        )
    }

    private func ncbiFetchProvenanceEnvelope(
        outputURL: URL,
        outputRecord: FileRecord,
        startedAt: Date,
        completedAt: Date,
        environment: [String: String],
        outputContent: String,
        fetchedRecords: [(accession: String, content: String)]?,
        retryEvents: [NCBIRetryEvent]
    ) throws -> ProvenanceEnvelope {
        let command = ncbiFetchCommand(outputPath: outputURL.path)
        let inputDescriptors = ncbiInputDescriptors(outputContent: outputContent, fetchedRecords: fetchedRecords)
        let outputDescriptor = ProvenanceFileDescriptor(fileRecord: outputRecord)
        let step = ProvenanceStep(
            toolName: "ncbi-efetch",
            toolVersion: "NCBI E-utilities API",
            argv: command,
            durableReplayArgv: command,
            inputs: inputDescriptors,
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        let legacyRun = WorkflowRun(
            name: "ncbi-sequence-fetch",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
            hostOS: WorkflowRun.currentHostOS,
            steps: [StepExecution(
                toolName: "ncbi-efetch",
                toolVersion: "NCBI E-utilities API",
                command: command,
                inputs: inputDescriptors.map(FileRecord.init(provenanceFile:)),
                outputs: [outputRecord],
                exitCode: 0,
                wallTime: completedAt.timeIntervalSince(startedAt),
                stderr: nil,
                startTime: startedAt,
                endTime: completedAt
            )],
            parameters: ncbiFetchParameters(
                outputURL: outputURL,
                environment: environment,
                retryEvents: retryEvents
            )
        )
        let parameters = ncbiFetchParameters(
            outputURL: outputURL,
            environment: environment,
            retryEvents: retryEvents
        )
        let defaults = ncbiFetchDefaults()
        return ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "ncbi-sequence-fetch",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "ncbi-efetch",
            toolVersion: "NCBI E-utilities API",
            argv: command,
            durableReplayArgv: command,
            reproducibleCommand: command.map(fetchShellEscape).joined(separator: " "),
            options: ProvenanceOptions(
                explicit: parameters,
                defaults: defaults,
                resolvedDefaults: resolvedProvenanceOptions(explicit: parameters, defaults: defaults)
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputDescriptors + [outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            legacyWorkflowRun: legacyRun
        )
    }

    private func ncbiFetchCommand(outputPath: String) -> [String] {
        var command = [CLICommandIdentity.executableName, "fetch", "ncbi"] + accessions + [
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

    private func ncbiFetchParameters(
        outputURL: URL,
        environment: [String: String],
        retryEvents: [NCBIRetryEvent]
    ) -> [String: ParameterValue] {
        [
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
    }

    private func ncbiFetchDefaults() -> [String: ParameterValue] {
        [
            "database": .string("nucleotide"),
            "fetchFormat": .string("fasta"),
            "resolvedFetchFormat": .string("fasta"),
            "saveTo": .null,
            "apiKeyProvided": .boolean(false),
            "retryEnabled": .boolean(true),
            "retryCount": .integer(0),
            "retryEvents": .array([]),
            "outputFormat": .string(OutputFormat.text.rawValue),
            "quiet": .boolean(false),
            "endpoint": .string("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"),
            "containerRuntime": .string("none"),
            "condaEnvironment": .string("none")
        ]
    }

    private func ncbiInputDescriptors(
        outputContent: String,
        fetchedRecords: [(accession: String, content: String)]?
    ) -> [ProvenanceFileDescriptor] {
        let rettype = Self.ncbiRettype(for: fetchFormat)
        let records = fetchedRecords ?? accessions.map { (accession: $0, content: outputContent) }
        return records.map { record in
            let data = Data(record.content.utf8)
            return ProvenanceFileDescriptor(
                path: "ncbi://\(database)/\(record.accession)?rettype=\(rettype)",
                checksumSHA256: Self.sha256Hex(data),
                fileSize: UInt64(data.count),
                format: fileFormat(forFetchFormat: fetchFormat),
                role: .input
            )
        }
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

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
                var section = "# lungfish-cli fetch ncbi accession: \(record.accession)\n"
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

func resolvedProvenanceOptions(
    explicit: [String: ParameterValue],
    defaults: [String: ParameterValue]
) -> [String: ParameterValue] {
    var resolved = defaults
    explicit.forEach { key, value in
        resolved[key] = value
    }
    return resolved
}

func fetchShellEscape(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    let safeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./:=+-")
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
