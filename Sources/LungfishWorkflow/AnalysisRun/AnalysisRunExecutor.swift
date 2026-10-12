// AnalysisRunExecutor.swift - Runs one analysis command through its phases, from the plan to the last event
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// What the executor works with besides the tool.
public struct AnalysisRunServices: Sendable {
    /// Writes the root record.
    public var writer: ProvenanceWriter
    /// Builds viewer indexes for the finalize, keyed by analysis kind (E6). The command line passes
    /// its conformance over the `build-db` cores. Nil leaves a finalize that asks for an index
    /// with ``AnalysisRunError/noResultIndexer(_:)``.
    public var indexing: (any AnalysisResultIndexing)?
    /// Whether a cancel was requested before the run's task saw it, such as a SIGTERM the
    /// command's `SIGTERMCancellation` counted in its signal handler. The executor reads it beside
    /// `Task.isCancelled` at every cancel check, so a unit that fails because the cancel signalled
    /// its child still ends the run as cancelled (SWIFT X2). The default reports none.
    public var cancelRequested: @Sendable () -> Bool

    public init(
        writer: ProvenanceWriter = ProvenanceWriter(),
        indexing: (any AnalysisResultIndexing)? = nil,
        cancelRequested: @escaping @Sendable () -> Bool = { false }
    ) {
        self.writer = writer
        self.indexing = indexing
        self.cancelRequested = cancelRequested
    }

    /// The writer with the signing provider the environment names, and no index builder.
    public static var live: AnalysisRunServices {
        AnalysisRunServices()
    }
}

/// Owns the lifecycle of one analysis command run (2.7 A1, ARCH 2.2), so the command line and the
/// app's route through it write one tree.
///
/// The phases run in this order, and only the executor runs them.
///
/// | Phase | Who | Writes |
/// |---|---|---|
/// | P0 plan | the tool | nothing, so a refused request leaves no folder |
/// | P1 folder | executor | the folder, `analysis-metadata.json`, the run record, then an `output` event |
/// | P2 units | the tool, one unit at a time | unit folders and outputs, unit records |
/// | P3 finalize | the tool, for a completed run | summary, manifest, viewer index |
/// | P4 root record | executor, last, through `ProvenanceRunBuilder` and `ProvenanceWriter` | the root record |
/// | P5 source records | executor, for a completed run | source bundle records, or an info line for one it cannot write |
/// | P6 settle | executor | completes the run record, or records the outcome and keeps the folder hidden (E5) |
/// | P7 report | executor | the `complete` or `failed` event and the exit code |
///
/// A cancel request is the cancellation of the run's task, such as the command's
/// `SIGTERMCancellation` cancelling it, or the services' `cancelRequested`, which can report the
/// SIGTERM before the task is cancelled. The status `cancelled` and exit 125 come from that cancel
/// request and never from how a unit or its child process ended (SWIFT X2), so a unit that fails
/// or throws while a cancel is requested ends the run as cancelled. The cancelled path skips the
/// finalize, records only descriptors the tool already took and hashes no partial output, so it
/// ends well inside the grace the app's transport gives a cancelled command.
///
/// The executor keeps no state of its own. Each `execute` call keeps its run state in locals,
/// so one executor can run several requests (SWIFT X3).
public struct AnalysisRunExecutor: Sendable {
    public let services: AnalysisRunServices

    public init(services: AnalysisRunServices = .live) {
        self.services = services
    }

    /// Runs `request` with `tool` and reports how it ended. It never throws, because every ending
    /// is a report with a status, an exit code and, once the folder exists, a root record.
    public func execute<Tool: AnalysisRunTool>(
        _ tool: Tool,
        _ request: AnalysisRunRequest,
        events: AnalysisRunEvents
    ) async -> AnalysisRunReport {
        let clock = ProvenanceRunClock()
        let identity = tool.identity
        let journal = AnalysisRunJournal(events: events)
        journal.emit(.start(message: "Starting \(identity.displayName)."))

        // P0. The plan writes nothing.
        let plan: AnalysisRunPlan<Tool.Unit>
        do {
            guard !request.commandLine.isEmpty else {
                throw AnalysisRunError.missingCommandLine
            }
            plan = try await tool.plan(
                request,
                context: journal.planningContext(projectURL: request.destination.projectURL)
            )
            guard !plan.units.isEmpty else {
                throw AnalysisRunError.emptyPlan(identity.toolID)
            }
            // One folder holds one unit, so no unit writes over another's outputs while the root
            // record keeps the first one's digests.
            switch plan.layout {
            case .singleFolder where plan.units.count > 1:
                throw AnalysisRunError.oneFolderHoldsOneUnit(identity.toolID, unitCount: plan.units.count)
            case .singleFolder, .batchRoot, .sharedBatchRoot:
                break
            }
        } catch {
            // A refused plan exits with the code its error carries, so a command keeps its own
            // codes for the refusals it moved into the plan.
            let ending: AnalysisRunEnding = cancelIsRequested
                ? .cancelled
                : .failed(reason: Self.reason(for: error), exitCode: Self.planExitCode(for: error))
            return report(ending, identity: identity, folder: nil, recordURL: nil, finalization: nil, journal: journal)
        }
        // A cancel during the plan leaves no folder, like a refused plan.
        if cancelIsRequested {
            return report(.cancelled, identity: identity, folder: nil, recordURL: nil, finalization: nil, journal: journal)
        }

        // P1. The folder, its metadata and the run record, then the early output event.
        let folder: AnalysisRunFolder
        do {
            folder = try AnalysisRunFolder.prepare(
                destination: request.destination,
                toolID: identity.toolID,
                layout: plan.layout,
                command: request.commandLine.map(shellEscape).joined(separator: " "),
                startedAt: clock.startedAt
            )
        } catch {
            let reason = "The analysis folder could not be prepared: \(Self.reason(for: error))"
            return report(
                .failed(reason: reason, exitCode: AnalysisRunExitCode.workflowError),
                identity: identity,
                folder: nil,
                recordURL: nil,
                finalization: nil,
                journal: journal
            )
        }
        journal.emit(.output(path: folder.root.path, role: CLIEventArtifact.Role.analysisDirectory))
        plan.recordInputs.forEach(journal.recordInput)
        // The plan's options come first, and what the units and the finalize record merges in.
        journal.recordOptions(plan.options)

        // P2. Serial units with a cancellation check between them.
        let units = await runUnits(tool, plan: plan, folder: folder, journal: journal)

        // P3. The finalize runs only for a run its units leave completed.
        var ending: AnalysisRunEnding
        var finalization: AnalysisRunFinalization?
        var failureDetail: String?
        if units.cancelled {
            ending = .cancelled
        } else {
            switch tool.terminalPolicy.outcome(for: units.reports, unitCount: plan.units.count) {
            case .failed(let reason):
                ending = .failed(reason: reason, exitCode: AnalysisRunExitCode.workflowError)
                failureDetail = Self.failureDetail(of: units.reports, journal: journal)
            case .completed:
                (ending, finalization) = await finalize(
                    tool,
                    reports: units.reports,
                    layout: plan.layout,
                    folder: folder,
                    journal: journal
                )
            }
        }

        // P4. The root record, written last so no record written during the run wins.
        let unitsEnding = ending
        let record = writeRootRecord(
            RootRecordInput(
                identity: identity,
                request: request,
                options: journal.recordedOptions,
                finalization: finalization,
                clock: clock
            ),
            ending: ending,
            folder: folder,
            journal: journal
        )
        ending = record.ending

        // P5. Source bundle records of a completed run.
        if ending == .completed, let finalization {
            writeSourceRecords(finalization.sourceRecords, identity: identity, folder: folder, journal: journal)
        }

        // P6. Settle the run record.
        folder.settle(ending)

        // P7. The last event and the exit code. The detail belongs to the units' failure, so a run
        // whose record changed how it ends sends none.
        return report(
            ending,
            identity: identity,
            folder: folder,
            recordURL: record.url,
            finalization: finalization,
            failureDetail: ending == unitsEnding ? failureDetail : nil,
            journal: journal
        )
    }

    /// The bounded failure detail of the one unit whose failure fails the run, or nil when that
    /// unit recorded none or several units failed, so the detail always belongs to the reason of
    /// the `failed` line (2.7 A8d review, UX D11). A run of one unit and a batch whose policy stops
    /// at its first failed unit have one failed unit, and a batch whose every unit failed has
    /// several.
    static func failureDetail<Result>(
        of reports: [AnalysisUnitReport<Result>],
        journal: AnalysisRunJournal
    ) -> String? {
        let failed = reports.filter { !$0.outcome.completed }
        guard failed.count == 1, let text = journal.failureDetail(unit: failed[0].index) else {
            return nil
        }
        return AnalysisRunFailureDetail.bounded(text)
    }

    // MARK: - P3

    private func finalize<Tool: AnalysisRunTool>(
        _ tool: Tool,
        reports: [AnalysisUnitReport<Tool.UnitResult>],
        layout: AnalysisRunLayout,
        folder: AnalysisRunFolder,
        journal: AnalysisRunJournal
    ) async -> (AnalysisRunEnding, AnalysisRunFinalization?) {
        do {
            let finalization = try await tool.finalize(
                reports,
                context: journal.finalizeContext(
                    rootDirectory: folder.root,
                    layout: layout,
                    projectURL: folder.projectURL,
                    toolID: tool.identity.toolID,
                    indexing: services.indexing,
                    finalizeShare: tool.finalizeProgressShare
                )
            )
            // A cancel during the finalize drops what it wrote from the record, so nothing
            // partial is hashed.
            guard !cancelIsRequested else { return (.cancelled, nil) }
            finalization.warnings.forEach(journal.warn)
            if let options = finalization.options {
                journal.recordOptions(options)
            }
            return (.completed, finalization)
        } catch {
            guard !cancelIsRequested else { return (.cancelled, nil) }
            let reason = "The \(tool.identity.displayName) results could not be finished: \(Self.reason(for: error))"
            return (.failed(reason: reason, exitCode: AnalysisRunExitCode.workflowError), nil)
        }
    }

    // MARK: - P5

    private func writeSourceRecords(
        _ records: [any AnalysisSourceRecord],
        identity: AnalysisRunIdentity,
        folder: AnalysisRunFolder,
        journal: AnalysisRunJournal
    ) {
        let context = AnalysisSourceRecordContext(
            toolID: identity.toolID,
            analysisDirectory: folder.root,
            projectURL: folder.projectURL
        )
        for record in records {
            do {
                try record.write(context)
            } catch {
                // An info line, as the app logs it today, so the row reads Completed and the root
                // record's stderr, written in P4, still holds every warning of the run.
                journal.log(.info, "The run could not be added to a source bundle's analysis history: \(Self.reason(for: error))")
            }
        }
    }

    // MARK: - P7

    private func report(
        _ ending: AnalysisRunEnding,
        identity: AnalysisRunIdentity,
        folder: AnalysisRunFolder?,
        recordURL: URL?,
        finalization: AnalysisRunFinalization?,
        failureDetail: String? = nil,
        journal: AnalysisRunJournal
    ) -> AnalysisRunReport {
        // The last line seals the stream, and the report takes the warnings as they stand then,
        // so a tool callback that fires later neither follows the last line nor joins them.
        let message: String
        let warnings: [String]
        switch ending {
        case .completed:
            message = finalization?.completionDetail ?? "\(identity.displayName) finished."
            var artifacts = finalization?.artifacts ?? []
            if let recordURL {
                artifacts.append(
                    CLIEventArtifact(kind: "provenance", path: recordURL.path, role: CLIEventArtifact.Role.provenance)
                )
            }
            warnings = journal.finish(
                .complete(outputs: folder.map { [$0.root.path] } ?? [], message: message),
                artifacts: artifacts
            )
        case .failed:
            message = ending.message(displayName: identity.displayName) ?? ""
            warnings = journal.finish(.failed(message: message, detail: failureDetail))
        case .cancelled:
            message = ending.message(displayName: identity.displayName) ?? ""
            warnings = journal.finish(.failed(message: message, detail: nil))
        }
        return AnalysisRunReport(
            analysisDirectory: folder?.root,
            status: ending.status,
            warnings: warnings,
            exitCode: ending.exitCode,
            recordURL: recordURL,
            message: message
        )
    }

    /// Whether a cancel was requested, by the run's task being cancelled or through the services.
    /// Only this ends a run as cancelled.
    var cancelIsRequested: Bool {
        Task.isCancelled || services.cancelRequested()
    }

    /// The text a run gives for an error, its description. A cancellation error without a cancel
    /// request is a failure (SWIFT X2), and its own description says nothing useful.
    static func reason(for error: Error) -> String {
        if error is CancellationError {
            return "Stopped before it finished, with no cancel request."
        }
        return error.localizedDescription
    }

    /// The exit code of a run whose plan refused it with `error`, the code the error carries
    /// (``AnalysisRunExitCoding``), or the workflow error code. A carried code that would read as
    /// a success or a cancel, 0, 125 or one outside 1 to 255, reads as the workflow error code.
    static func planExitCode(for error: Error) -> Int32 {
        guard let coded = error as? any AnalysisRunExitCoding else {
            return AnalysisRunExitCode.workflowError
        }
        let code = coded.analysisRunExitCode
        guard (1...255).contains(code), code != AnalysisRunExitCode.cancelled else {
            return AnalysisRunExitCode.workflowError
        }
        return code
    }
}

/// How a run ended, inside the executor.
enum AnalysisRunEnding: Sendable, Equatable {
    case completed
    /// The run failed for `reason`. Its command exits with `exitCode`, which is
    /// `AnalysisRunExitCode.workflowError` for every failure but a refused plan whose error
    /// carries its own code.
    case failed(reason: String, exitCode: Int32)
    /// A cancel was requested. Only a cancel request ends a run this way.
    case cancelled

    var status: RunStatus {
        switch self {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    var exitCode: Int32 {
        switch self {
        case .completed: return AnalysisRunExitCode.completed
        case .failed(_, let exitCode): return exitCode
        case .cancelled: return AnalysisRunExitCode.cancelled
        }
    }

    /// Why the run did not complete, for the root record and the `failed` event. Nil when it completed.
    func message(displayName: String) -> String? {
        switch self {
        case .completed: return nil
        case .failed(let reason, _): return reason
        case .cancelled: return "\(displayName) was cancelled."
        }
    }
}
