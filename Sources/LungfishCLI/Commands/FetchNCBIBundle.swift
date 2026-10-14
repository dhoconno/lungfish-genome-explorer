// FetchNCBIBundle.swift - lungfish-cli fetch ncbi --bundle, one .lungfishref bundle for each accession
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension NCBISubcommand {
    /// The `--bundle` run (Phase 2.10 lane A45). SIGTERM, which the Operations panel's Cancel sends,
    /// cancels the run, so the bundle it was building is removed before the command exits 125. It
    /// listens before the task starts, and a SIGTERM caught before then cancels the task as soon as it
    /// exists. A second SIGTERM ends the command at once. A bundle already published stays, with its
    /// record.
    func runBundle() async throws {
        let reporter = FetchGenomeReporter(
            eventsOn: globalOptions.outputFormat == .json,
            quiet: globalOptions.quiet,
            useColors: globalOptions.useColors,
            subject: "NCBI bundle"
        )
        let run = FetchNCBIBundleRun(request: FetchNCBIBundleRequest(command: self), reporter: reporter)
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

/// The options of one `fetch ncbi --bundle` run, resolved to URLs.
struct FetchNCBIBundleRequest: Sendable {
    let accessions: [String]
    let outputURL: URL
    let includeGFF3Annotations: Bool
    let apiKey: String?
    let outputFormat: OutputFormat
    let quiet: Bool

    init(command: NCBISubcommand) {
        accessions = command.accessions
        outputURL = URL(fileURLWithPath: command.outputDir ?? ".").standardizedFileURL
        includeGFF3Annotations = !command.noGFF3
        apiKey = command.apiKey
        outputFormat = command.globalOptions.outputFormat
        quiet = command.globalOptions.quiet
    }
}

/// One `fetch ncbi --bundle` run. Each accession builds through `GenBankDownloadBundleBuilder`, the
/// builder of the app's NCBI browser, so the CLI and the browser build the same bundle, with the one
/// sequence named by the accession with its version.
///
/// - The bundle is built in a staging folder, the project's `.tmp` folder or a hidden folder of the
///   output folder outside a project, and moved into the output folder with `PortableRename` under
///   the next free name (`_1`, `_2`, as the import names them).
/// - The builder's record names the staging folder the run deletes, so it gives way to the record of
///   what was fetched, written in place once the bundle is published (A44 M2 review, F9).
/// - A run checks for a cancel before each accession and between the builder's stages, and removes
///   the bundle it was building. A run goes on past an accession that fails.
struct FetchNCBIBundleRun: Sendable {
    let request: FetchNCBIBundleRequest
    let reporter: FetchGenomeReporter

    func fetchAll() async -> FetchGenomeOutcome {
        var outcome = FetchGenomeOutcome()
        do {
            try FileManager.default.createDirectory(at: request.outputURL, withIntermediateDirectories: true)
        } catch {
            outcome.failures.append(.init(
                accession: "", message: "Could not create \(request.outputURL.path): \(error.localizedDescription)"))
            return outcome
        }
        let service = NCBIService(apiKey: request.apiKey)
        let count = request.accessions.count
        for (index, accession) in request.accessions.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            reporter.beginAccession(accession, index: index, count: count, destination: request.outputURL)
            let progress = reporter.progressHandler(accession: accession, index: index, count: count)
            do {
                let output = try await fetch(accession, service: service, progress: progress)
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

    private func fetch(
        _ accession: String,
        service: NCBIService,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchGenomeOutput {
        let staging = try Self.makeStagingFolder(for: request.outputURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        let built = try await GenBankDownloadBundleBuilder(ncbiService: service).downloadAndBuild(
            accession: accession,
            outputDirectory: staging,
            includeGFF3Annotations: request.includeGFF3Annotations,
            sequenceNaming: .accessionVersion,
            namesFetchedRecord: true,
            progressHandler: progress
        )
        try Task.checkCancellation()
        let bundleURL = try FetchGenomeRun.publish(built, into: request.outputURL)
        // A bundle in its final place is finished, so a cancel from here on does not undo it, and a
        // record that cannot be rewritten removes the bundle.
        do {
            try FetchNCBIBundleRecord.rebase(bundle: bundleURL, from: built)
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
        return .bundle(bundleURL, record: FetchGenomeRun.rootRecord(of: bundleURL))
    }

    /// The project's `.tmp` folder when `directory` is inside a project, or else a hidden folder in
    /// `directory`, so the bundle moves into place by a rename on the same volume. `prefix` names
    /// the command that stages (`fetch pathoplexus` stages with its own).
    static func makeStagingFolder(for directory: URL, prefix: String = "fetch-ncbi-") throws -> URL {
        if let project = ProjectTempDirectory.findProjectRoot(directory) {
            return try ProjectTempDirectory.create(prefix: prefix, in: project)
        }
        let folder = directory.appendingPathComponent(".\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
