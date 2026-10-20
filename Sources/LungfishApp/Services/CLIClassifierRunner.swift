// CLIClassifierRunner.swift - Runs kraken2 classify or esviritu detect through CLISubprocessTransport for the app's row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishKit
import LungfishWorkflow
import Synchronization

/// One classifier run through `lungfish-cli`, as the CLI route hands it to the runner.
struct CLIClassifierRunRequest: Sendable, Equatable {
    let tool: CLIClassifierTool
    /// The argv after `lungfish-cli`, the command the row records.
    let arguments: [String]
    /// Today's sample ids in plan order. More than one makes a batch.
    let sampleIDs: [String]

    var isBatch: Bool {
        sampleIDs.count > 1
    }
}

/// How a classifier run through `lungfish-cli` completed, read back from the result on disk.
struct CLIClassifierCompletion: Sendable {
    /// The result folder.
    let folder: URL?
    /// Today's completion detail.
    let detail: String
    /// Whether today's row completes with a warning, whose line is the detail.
    let completesWithWarning: Bool
    /// The result the taxonomy browser opens at the end of a Kraken2 run, the first completed
    /// sample's in a batch.
    let taxonomyResult: ClassificationResult?
    /// Why the result could not be read back, for one warning line, or nil.
    let readBackProblem: String?
    /// Today's warning lines that the result on disk gives and no command line carries, such as the
    /// legacy TaxTriage row's line for its failed samples. They make the label, so the row completes
    /// plainly with its detail (2.8 T9, D4).
    var warnings: [String] = []
}

/// Why a classifier run through `lungfish-cli` failed, in today's words.
struct CLIClassifierFailure: Error, LocalizedError, Sendable, Equatable {
    /// The row's detail and the alert's text, the command's `failed` message.
    let message: String
    /// The row's error message, which today's single EsViritu run sets.
    let errorMessage: String?
    /// The row's error detail, the EsViritu log tail.
    let errorDetail: String?

    var errorDescription: String? {
        message
    }
}

/// Runs `lungfish-cli kraken2 classify` or `esviritu detect` for the app's CLI route (Phase 2.7
/// lane A10) and shows the run in its Operations panel row as today's in-process route does.
///
/// `OperationCenterCLIBridge` moves the bar, sets the detail and logs. The runner hands it the
/// events ``CLIClassifierRowEvents`` makes of the command's events, and hops to the main actor
/// itself only for the viewer's overlay and for tracking the result folder the early `output`
/// line names. After the command completed, the runner reads the result back from disk, off the
/// main actor, and builds today's completion detail with the builders the command shares
/// (`ClassificationBatchOutcomePolicy`, `ClassificationCompletionDetail`). It writes nothing.
///
/// A cancel goes through the transport. The command gets SIGTERM and ``terminationGracePeriod``
/// to record its run as cancelled before SIGKILL, under the ten seconds `OperationCenter` waits
/// for a cancelling row.
struct CLIClassifierRunner {
    /// The time the command has between SIGTERM and SIGKILL to record its cancelled run, the
    /// launcher's ``CLIProcessLauncher/operationGrace``.
    static let terminationGracePeriod = CLIProcessLauncher.operationGrace
    /// How long the run waits for a descendant that holds the command's output open after the
    /// command exited, the launcher's ``CLIProcessLauncher/operationDrain``.
    static let drainGracePeriod = CLIProcessLauncher.operationDrain

    /// Whether a cancel sends SIGTERM to the command alone, so the command stops its own tree and
    /// its cleanup runs before SIGKILL. `taxtriage run` stops Nextflow and then removes the run's
    /// Docker containers with `docker`, which a SIGTERM to every descendant killed, so its cancel
    /// left the containers behind where the legacy route's in-app cleanup removed them (U30 walk W2).
    static func signalsCommandFirst(_ tool: CLIClassifierTool) -> Bool {
        tool == .taxTriage
    }

    private let transport: CLISubprocessTransport

    init(cliURLOverride: URL? = nil) {
        transport = CLISubprocessTransport(cliURLOverride: cliURLOverride)
    }

    /// Stops the command, whether it is running or about to start. It returns at once.
    func cancel() {
        transport.cancel()
    }

    /// Runs `request` for the row `operationID` and returns how it completed. It runs on the
    /// concurrent executor by declaration, so the read-back of the result stays off the main
    /// actor whatever isolation the caller has.
    ///
    /// - Parameter showProgress: The viewer's progress overlay, called on the main actor with
    ///   every line the row shows.
    /// - Throws: `CancellationError` when the run was cancelled, else ``CLIClassifierFailure``.
    @concurrent
    func run(
        _ request: CLIClassifierRunRequest,
        operationID: UUID,
        showProgress: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) async throws -> CLIClassifierCompletion {
        let state = CLIClassifierRowEventState(CLIClassifierRowEvents(tool: request.tool, sampleIDs: request.sampleIDs))
        let bridge = OperationCenterCLIBridge.onEvent(operationID: operationID)
        let result: CLISubprocessTransport.Result
        do {
            result = try await transport.run(
                arguments: request.arguments,
                terminationGracePeriod: Self.terminationGracePeriod,
                signalsCommandFirst: Self.signalsCommandFirst(request.tool),
                drainGracePeriod: Self.drainGracePeriod,
                isCancelled: { await OperationCenterCLIBridge.isOperationCancelled(operationID) },
                onEvent: { event in
                    let effects = state.effects(of: event)
                    effects.bridged.forEach(bridge)
                    if let line = effects.overlay {
                        // Only while the row runs, as the bridge's update, so a line after a cancel
                        // never replaces what the overlay shows (Phase 2.9 UX inventory T2).
                        Task { @MainActor in
                            if OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running { showProgress(line) }
                        }
                    }
                    if let folder = effects.trackedFolder {
                        Task { @MainActor in OperationCenter.shared.trackAnalysisOutput(folder, for: operationID) }
                    }
                }
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.failure(for: error, request: request, events: state.snapshot)
        }
        return Self.completion(of: request, events: state.snapshot, result: result)
    }

    // MARK: - Failure

    /// Today's failure of `request` for a transport error. The alert shows the command's
    /// `failed` message, never its detail. A single EsViritu run puts the line's detail, the last
    /// lines of EsViritu's log, in the error detail under today's heading (A8d review, UX D11). A
    /// single TaxTriage run keeps the line's detail, Nextflow's standard error, as its error detail
    /// (U30 M2). A Kraken2 run and every batch keep no error detail, as today, even when a detail
    /// arrives, and a batch whose every sample failed reads today's first sample error.
    static func failure(
        for error: Error,
        request: CLIClassifierRunRequest,
        events: CLIClassifierRowEvents
    ) -> CLIClassifierFailure {
        var message = error.localizedDescription
        var detail: String?
        if case let CLISubprocessTransport.RunError.failedEvent(failedMessage, failedDetail) = error {
            message = failedMessage
            detail = failedDetail.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch (request.tool, request.isBatch) {
        case (.kraken2, false):
            return CLIClassifierFailure(message: message, errorMessage: nil, errorDetail: nil)
        case (.taxTriage, false):
            // The command's detail of a failed launch is Nextflow's standard error, kept for the row.
            return CLIClassifierFailure(message: message, errorMessage: nil, errorDetail: detail)
        case (.taxTriage, true) where events.everyUnitFailed:
            // The words a TaxTriage batch with no sample left has always shown (TaxTriageSerialBatchError).
            let first = events.failedUnitReasons.first.map {
                TaxTriageSampleFailure(sampleID: "", outputDirectory: events.analysisFolder ?? URL(fileURLWithPath: "/"), errorDescription: $0)
            }
            let words = TaxTriageSerialBatchError.allSamplesFailed(first.map { [$0] } ?? []).errorDescription ?? message
            return CLIClassifierFailure(message: words, errorMessage: nil, errorDetail: nil)
        case (.esViritu, false):
            return CLIClassifierFailure(
                message: message,
                errorMessage: message,
                errorDetail: detail.map { CLIClassifierRowEvents.esVirituLogTailHeading + $0 }
            )
        case (_, true):
            let batchMessage = events.everyUnitFailed
                ? ClassificationCompletionDetail.allSamplesFailed(firstError: events.failedUnitReasons.first)
                : message
            return CLIClassifierFailure(message: batchMessage, errorMessage: nil, errorDetail: nil)
        }
    }

    // MARK: - Completion

    /// Reads the completed result back from disk and builds today's completion. A result that
    /// cannot be read keeps the command's own completion message and names the problem.
    static func completion(
        of request: CLIClassifierRunRequest,
        events: CLIClassifierRowEvents,
        result: CLISubprocessTransport.Result
    ) -> CLIClassifierCompletion {
        let commandDetail = result.message ?? ""
        guard let folder = events.analysisFolder ?? result.outputs.first.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            return CLIClassifierCompletion(
                folder: nil,
                detail: commandDetail,
                completesWithWarning: false,
                taxonomyResult: nil,
                readBackProblem: "lungfish-cli named no result folder, so the result was not read back."
            )
        }
        do {
            switch (request.tool, request.isBatch) {
            case (.kraken2, false):
                return try kraken2Completion(folder: folder)
            case (.kraken2, true):
                return try kraken2BatchCompletion(folder: folder, databaseError: events.databaseError)
            case (.esViritu, false):
                return try esVirituCompletion(folder: folder)
            case (.esViritu, true):
                return try esVirituBatchCompletion(folder: folder)
            case (.taxTriage, _):
                return try taxTriageCompletion(folder: folder)
            }
        } catch {
            return CLIClassifierCompletion(
                folder: folder,
                detail: commandDetail,
                completesWithWarning: false,
                taxonomyResult: nil,
                readBackProblem: "The result in \(folder.lastPathComponent) could not be read back: \(error.localizedDescription)"
            )
        }
    }

    private static func kraken2Completion(folder: URL) throws -> CLIClassifierCompletion {
        let result = try ClassificationResult.load(from: folder)
        let metadata = ClassificationBatchOutcomePolicy.singleResultMetadata(for: result)
        return CLIClassifierCompletion(
            folder: folder,
            detail: metadata.completionDetail,
            completesWithWarning: metadata.requiresWarningCompletion,
            taxonomyResult: result,
            readBackProblem: nil
        )
    }

    private static func kraken2BatchCompletion(folder: URL, databaseError: String?) throws -> CLIClassifierCompletion {
        guard let manifest = MetagenomicsBatchResultStore.loadClassification(from: folder) else {
            throw CLIClassifierReadBackError.missingManifest(ClassificationBatchResultManifest.filename)
        }
        let results = try manifest.samples.map { sample in
            try ClassificationResult.load(from: folder.appendingPathComponent(sample.resultDirectory, isDirectory: true))
        }
        let sampleCount = manifest.header.sampleCount
        let failedCount = manifest.failedCount ?? max(0, sampleCount - manifest.samples.count)
        let rows = zip(manifest.samples, results).map { ClassificationBatchOutcomePolicy.row(sampleId: $0.sampleId, result: $1) }
            + (0..<failedCount).map { ClassificationBatchOutcomePolicy.failedRow(sampleId: "failed-\($0 + 1)", message: "") }
        let evaluation = ClassificationBatchOutcomePolicy.evaluate(rows: rows, sqliteWarning: databaseError)
        return CLIClassifierCompletion(
            folder: folder,
            detail: ClassificationCompletionDetail.kraken2Batch(
                successCount: manifest.samples.count,
                sampleCount: sampleCount,
                evaluation: evaluation
            ),
            completesWithWarning: evaluation.requiresWarningCompletion,
            taxonomyResult: results.first,
            readBackProblem: nil
        )
    }

    /// One EsViritu sample, which a `--project` run keeps in the sample folder of a batch root,
    /// as today's in-process route does (UX D23).
    private static func esVirituCompletion(folder: URL) throws -> CLIClassifierCompletion {
        let sampleFolder = MetagenomicsBatchResultStore.loadEsViritu(from: folder)?.samples.first
            .map { folder.appendingPathComponent($0.resultDirectory, isDirectory: true) } ?? folder
        let result = try LungfishWorkflow.EsVirituResult.load(from: sampleFolder)
        let detections = try EsVirituDetectionParser.parse(url: result.detectionURL)
        return CLIClassifierCompletion(
            folder: folder,
            detail: ClassificationCompletionDetail.esVirituDetection(
                virusCount: detections.count,
                familyCount: Set(detections.compactMap(\.family)).count
            ),
            completesWithWarning: false,
            taxonomyResult: nil,
            readBackProblem: nil
        )
    }

    /// A TaxTriage result, the one sample's that a `--project` run writes into its batch folder or
    /// the aggregate result of a batch root, read with the words the in-process route's end gave it
    /// until Phase 2.12 K1 deleted that route. A run with ignored task failures or failed samples
    /// completes with a detail that names them and its report count, a run with neither with the
    /// result's summary. The failed samples get today's one warning line. The paragraph of ignored
    /// task failures is a line of the command, which the row keeps as a warning.
    static func taxTriageCompletion(folder: URL) throws -> CLIClassifierCompletion {
        let result = try TaxTriageResult.load(from: folder)
        var summaries: [String] = []
        var warnings: [String] = []
        if let headline = result.erroredProcessesHeadline {
            summaries.append(headline)
        }
        if result.hasSampleFailures {
            summaries.append(counted(result.sampleFailures.count, "failed sample"))
            let preview = result.sampleFailures.prefix(5).map { "\($0.sampleID): \($0.errorDescription)" }.joined(separator: "; ")
            let more = result.sampleFailures.count > 5 ? "; +\(result.sampleFailures.count - 5) more" : ""
            warnings.append("\(counted(result.sampleFailures.count, "TaxTriage sample")) failed (\(preview)\(more))")
        }
        let detail = result.completedWithErrors && !summaries.isEmpty
            ? "\(summaries.joined(separator: "; ")) (\(counted(result.reportFiles.count, "report")))"
            : result.summary
        return CLIClassifierCompletion(
            folder: folder,
            detail: detail,
            completesWithWarning: false,
            taxonomyResult: nil,
            readBackProblem: nil,
            warnings: warnings
        )
    }

    /// `1 report` or `2 reports`, a count and its noun in the number it takes, as the legacy row words it.
    private static func counted(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func esVirituBatchCompletion(folder: URL) throws -> CLIClassifierCompletion {
        guard let manifest = MetagenomicsBatchResultStore.loadEsViritu(from: folder) else {
            throw CLIClassifierReadBackError.missingManifest(EsVirituBatchResultManifest.filename)
        }
        let sampleCount = manifest.header.sampleCount
        return CLIClassifierCompletion(
            folder: folder,
            detail: ClassificationCompletionDetail.esVirituBatch(
                successCount: manifest.samples.count,
                failureCount: max(0, sampleCount - manifest.samples.count),
                sampleCount: sampleCount
            ),
            completesWithWarning: false,
            taxonomyResult: nil,
            readBackProblem: nil
        )
    }
}

/// Why a completed result could not be read back.
enum CLIClassifierReadBackError: Error, LocalizedError, Equatable {
    case missingManifest(String)

    var errorDescription: String? {
        switch self {
        case .missingManifest(let name):
            return "\(name) is missing or unreadable"
        }
    }
}

/// The row events of one run behind a lock, because the transport calls in from its reader queue.
private final class CLIClassifierRowEventState: Sendable {
    private let events: Mutex<CLIClassifierRowEvents>

    init(_ events: CLIClassifierRowEvents) {
        self.events = Mutex(events)
    }

    func effects(of event: CLIEvent) -> CLIClassifierRowEvents.Effects {
        events.withLock { $0.effects(of: event) }
    }

    var snapshot: CLIClassifierRowEvents {
        events.withLock { $0 }
    }
}
