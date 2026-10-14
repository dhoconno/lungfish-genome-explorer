// FetchPathoplexus.swift - lungfish-cli fetch pathoplexus, one .lungfishref bundle for each Pathoplexus record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Fetch Pathoplexus records as bundles (Phase 2.10 lane A45 M2).
struct PathoplexusSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pathoplexus",
        abstract: "Fetch Pathoplexus records into .lungfishref bundles",
        discussion: """
            Download Pathoplexus records by accession, one .lungfishref bundle for each in
            --output-dir, built as the app's Pathoplexus browser builds a record.

            A record whose data use terms are restricted is refused. A record with an INSDC
            accession is built from its GenBank record, with Pathoplexus's metadata added to the
            manifest and the one sequence named by the INSDC accession with its version. A record
            with no INSDC accession, or one that GenBank cannot serve, is built from the
            Pathoplexus FASTA, which the bundle keeps as sources/record.fasta. Each bundle holds a
            provenance record that names the accession with its version, the date of the fetch and
            the digest of what arrived, as a live snapshot.

            With --format json the command prints CLIEvent lines on standard output and its human
            text on standard error. SIGTERM stops the run, removes the bundle it was building and
            exits 125. Pathoplexus takes no key. The NCBI key, used only to read a GenBank record,
            comes from --api-key or from the NCBI_API_KEY environment variable.

            Examples:
              lungfish-cli fetch pathoplexus PP_0012345 --organism mpox --output-dir ./bundles
              lungfish-cli fetch pathoplexus PP_0012345 PP_0012346 --organism mpox --no-gff3 --format json
            """
    )

    @Argument(help: "Pathoplexus accession(s), such as PP_0012345")
    var accessions: [String]

    @Option(
        name: .customLong("organism"),
        help: "Pathoplexus organism id, such as mpox (required, since accessions are not organism-scoped)"
    )
    var organism: String

    @Option(
        name: .customLong("output-dir"),
        help: "The folder for the bundles (default: current directory)"
    )
    var outputDir: String?

    @Flag(
        name: .customLong("no-gff3"),
        help: "For a record read from GenBank, fetch no GFF3 and take the annotations from the GenBank record"
    )
    var noGFF3: Bool = false

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits when a record is read from GenBank"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        guard !organism.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--organism needs a Pathoplexus organism id, such as mpox.")
        }
    }

    /// SIGTERM, which the Operations panel's Cancel sends, cancels the run, so the bundle it was
    /// building is removed before the command exits 125. It listens before the task starts, and a
    /// SIGTERM caught before then cancels the task as soon as it exists. A second SIGTERM ends the
    /// command at once. A bundle already published stays, with its record.
    func run() async throws {
        let reporter = FetchGenomeReporter(
            eventsOn: globalOptions.outputFormat == .json,
            quiet: globalOptions.quiet,
            useColors: globalOptions.useColors,
            subject: "Pathoplexus record"
        )
        let run = FetchPathoplexusRun(request: FetchPathoplexusRequest(command: self), reporter: reporter)
        reporter.start(accessions: accessions)
        let pendingCancel = PendingTaskCancel<FetchGenomeOutcome>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let task = Task { await run.fetchAll() }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        try reporter.finish(outcome)
    }
}

/// The options of one `fetch pathoplexus` run, resolved to URLs.
struct FetchPathoplexusRequest: Sendable {
    let accessions: [String]
    let organism: String
    let outputURL: URL
    let includeGFF3Annotations: Bool
    let apiKey: String?
    let outputFormat: OutputFormat
    let quiet: Bool

    init(command: PathoplexusSubcommand) {
        accessions = command.accessions
        organism = command.organism.trimmingCharacters(in: .whitespacesAndNewlines)
        outputURL = URL(fileURLWithPath: command.outputDir ?? ".").standardizedFileURL
        includeGFF3Annotations = !command.noGFF3
        apiKey = command.apiKey
        outputFormat = command.globalOptions.outputFormat
        quiet = command.globalOptions.quiet
    }

    /// The command that fetches `accession` alone, with the key left out.
    func command(for accession: String) -> [String] {
        var command = [CLICommandIdentity.executableName, "fetch", "pathoplexus", accession, "--organism", organism]
        command += ["--output-dir", outputURL.path]
        if !includeGFF3Annotations { command.append("--no-gff3") }
        if apiKey != nil { command += ["--api-key", "<redacted>"] }
        if outputFormat != .text { command += ["--format", outputFormat.rawValue] }
        if quiet { command.append("--quiet") }
        return command
    }
}

/// One `fetch pathoplexus` run. Each accession takes one of the ways of the app's Pathoplexus row
/// (`DatabaseBrowserViewModel+PathoplexusRowDownload.swift`), so the CLI and the browser build the
/// same bundle.
///
/// - A restricted record is refused with `DatabaseServiceError.invalidQuery`, before anything is
///   staged.
/// - A record with an INSDC accession builds through `GenBankDownloadBundleBuilder`, with the one
///   sequence named by the accession with its version, and Pathoplexus's metadata groups appended
///   to the manifest. When GenBank cannot serve it, the bundle is built from the Pathoplexus FASTA.
/// - A record with no INSDC accession builds from the Pathoplexus FASTA.
///
/// The bundle is built in a staging folder, the project's `.tmp` folder or a hidden folder of the
/// output folder outside a project, and moved into the output folder with `PortableRename` under
/// the next free name. A run checks for a cancel before each accession and between the builder's
/// stages, and removes the bundle it was building. A run goes on past an accession that fails.
struct FetchPathoplexusRun: Sendable {
    let request: FetchPathoplexusRequest
    let reporter: FetchGenomeReporter

    static let stagingPrefix = "fetch-pathoplexus-"

    func fetchAll() async -> FetchGenomeOutcome {
        var outcome = FetchGenomeOutcome()
        do {
            try FileManager.default.createDirectory(at: request.outputURL, withIntermediateDirectories: true)
        } catch {
            outcome.failures.append(.init(
                accession: "", message: "Could not create \(request.outputURL.path): \(error.localizedDescription)"))
            return outcome
        }
        let services = Services(pathoplexus: PathoplexusService(), ncbi: NCBIService(apiKey: request.apiKey))
        let count = request.accessions.count
        for (index, accession) in request.accessions.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            reporter.beginAccession(accession, index: index, count: count, destination: request.outputURL)
            let progress = reporter.progressHandler(accession: accession, index: index, count: count)
            do {
                let output = try await fetch(accession, services: services, progress: progress)
                outcome.outputs.append(output)
                reporter.finishedAccession(output)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    outcome.cancelled = true
                    break
                }
                let failure = FetchGenomeOutcome.Failure(accession: accession, message: FetchGenomeRun.message(for: error))
                outcome.failures.append(failure)
                reporter.failedAccession(failure)
            }
        }
        return outcome
    }

    /// The two services of a run. Pathoplexus takes no key, and NCBI's is read for a GenBank record.
    struct Services: Sendable {
        let pathoplexus: PathoplexusService
        let ncbi: NCBIService
    }

    typealias Progress = @Sendable (Double, String) -> Void

    private func fetch(_ accession: String, services: Services, progress: @escaping Progress) async throws -> FetchGenomeOutput {
        let runClock = ProvenanceRunClock()
        let normalized = accession.trimmingCharacters(in: .whitespacesAndNewlines)
        progress(0, "Reading Pathoplexus metadata...")
        let meta = try await services.pathoplexus.fetchMetadataForAccession(organism: request.organism, accession: normalized)
        if meta?.dataUseTerms?.uppercased() == DataUseTerms.restricted.rawValue {
            throw DatabaseServiceError.invalidQuery(reason: "Record \(normalized) is restricted and cannot be downloaded")
        }
        let staging = try FetchNCBIBundleRun.makeStagingFolder(for: request.outputURL, prefix: Self.stagingPrefix)
        defer { try? FileManager.default.removeItem(at: staging) }

        var triedGenBank = false
        var genBankBundle: URL?
        if let insdc = meta?.bestINSDCAccession?.trimmingCharacters(in: .whitespacesAndNewlines), !insdc.isEmpty {
            triedGenBank = true
            // Any failure to build from GenBank falls back to the Pathoplexus FASTA, so the record
            // still downloads. A cancel does not, and neither does a failure to publish the bundle.
            do {
                progress(0, "Fetching GenBank record \(insdc)...")
                let built = try await GenBankDownloadBundleBuilder(ncbiService: services.ncbi).downloadAndBuild(
                    accession: insdc,
                    outputDirectory: staging,
                    includeGFF3Annotations: request.includeGFF3Annotations,
                    sequenceNaming: .accessionVersion,
                    namesFetchedRecord: true,
                    progressHandler: progress
                )
                try Task.checkCancellation()
                if let meta {
                    appendPathoplexusMetadata(meta, organism: request.organism, toBundleAt: built)
                }
                genBankBundle = built
            } catch {
                if Task.isCancelled || error is CancellationError { throw error }
                progress(0, "GenBank unavailable for \(normalized); falling back to FASTA...")
            }
        }
        if let built = genBankBundle {
            return try publishGenBankBundle(built, meta: meta, accession: normalized)
        }
        let notes = triedGenBank
            ? "Generated from Pathoplexus FASTA fallback after INSDC lookup failed"
            : "Generated from Pathoplexus sequence (no INSDC accession available)"
        return try await buildFromFASTA(
            normalized, meta: meta, notes: notes, services: services, staging: staging, runClock: runClock, progress: progress)
    }
}
