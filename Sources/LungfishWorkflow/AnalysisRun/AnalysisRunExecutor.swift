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

    public init(writer: ProvenanceWriter = ProvenanceWriter(), indexing: (any AnalysisResultIndexing)? = nil) {
        self.writer = writer
        self.indexing = indexing
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
/// | P5 source records | executor, for a completed run | source bundle records |
/// | P6 settle | executor | completes the run record, or records the outcome and keeps the folder hidden (E5) |
/// | P7 report | executor | the `complete` or `failed` event and the exit code |
///
/// A cancel is task cancellation only, such as the command's `SIGTERMCancellation` cancelling
/// its task. The status `cancelled` and exit 125 come from that cancel request and never from
/// how a unit or its child process ended (SWIFT X2). The cancelled path skips the finalize,
/// records only descriptors the tool already took and hashes no partial output, so it ends well
/// inside the grace the app's transport gives a cancelled command.
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
        } catch {
            let ending: AnalysisRunEnding = Task.isCancelled ? .cancelled : .failed(reason: Self.reason(for: error))
            return report(ending, identity: identity, folder: nil, recordURL: nil, finalization: nil, journal: journal)
        }
        // A cancel during the plan leaves no folder, like a refused plan.
        if Task.isCancelled {
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
            return report(.failed(reason: reason), identity: identity, folder: nil, recordURL: nil, finalization: nil, journal: journal)
        }
        journal.emit(.output(path: folder.root.path, role: CLIEventArtifact.Role.analysisDirectory))
        plan.recordInputs.forEach(journal.recordInput)

        // P2. Serial units with a cancellation check between them.
        let units = await runUnits(tool, plan: plan, folder: folder, journal: journal)

        // P3. The finalize runs only for a run its units leave completed.
        var ending: AnalysisRunEnding
        var finalization: AnalysisRunFinalization?
        if units.cancelled {
            ending = .cancelled
        } else {
            switch tool.terminalPolicy.outcome(for: units.reports, unitCount: plan.units.count) {
            case .failed(let reason):
                ending = .failed(reason: reason)
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
        let record = writeRootRecord(
            RootRecordInput(
                identity: identity,
                request: request,
                options: plan.options,
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

        // P7. The last event and the exit code.
        return report(
            ending,
            identity: identity,
            folder: folder,
            recordURL: record.url,
            finalization: finalization,
            journal: journal
        )
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
                    indexing: services.indexing
                )
            )
            // A cancel during the finalize drops what it wrote from the record, so nothing
            // partial is hashed.
            guard !Task.isCancelled else { return (.cancelled, nil) }
            finalization.warnings.forEach(journal.warn)
            return (.completed, finalization)
        } catch {
            guard !Task.isCancelled else { return (.cancelled, nil) }
            let reason = "The \(tool.identity.displayName) results could not be finished: \(Self.reason(for: error))"
            return (.failed(reason: reason), nil)
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
                journal.warn("The run could not be added to a source bundle's analysis history: \(Self.reason(for: error))")
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
        journal: AnalysisRunJournal
    ) -> AnalysisRunReport {
        let message: String
        switch ending {
        case .completed:
            message = finalization?.completionDetail ?? "\(identity.displayName) finished."
            var artifacts = finalization?.artifacts ?? []
            if let recordURL {
                artifacts.append(
                    CLIEventArtifact(kind: "provenance", path: recordURL.path, role: CLIEventArtifact.Role.provenance)
                )
            }
            journal.emit(.complete(outputs: folder.map { [$0.root.path] } ?? [], message: message), artifacts: artifacts)
        case .failed, .cancelled:
            message = ending.message(displayName: identity.displayName) ?? ""
            journal.emit(.failed(message: message, detail: nil))
        }
        return AnalysisRunReport(
            analysisDirectory: folder?.root,
            status: ending.status,
            warnings: journal.warnings,
            exitCode: ending.exitCode,
            recordURL: recordURL,
            message: message
        )
    }

    /// The text a run gives for an error, its description. A cancellation error without a cancel
    /// request is a failure (SWIFT X2), and its own description says nothing useful.
    static func reason(for error: Error) -> String {
        if error is CancellationError {
            return "Stopped before it finished, with no cancel request."
        }
        return error.localizedDescription
    }
}

/// How a run ended, inside the executor.
enum AnalysisRunEnding: Sendable, Equatable {
    case completed
    case failed(reason: String)
    /// The run's task was cancelled. Only a cancel request ends a run this way.
    case cancelled

    var status: RunStatus {
        switch self {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }

    var exitCode: Int32 {
        AnalysisRunExitCode.code(for: status)
    }

    /// Why the run did not complete, for the root record and the `failed` event. Nil when it completed.
    func message(displayName: String) -> String? {
        switch self {
        case .completed: return nil
        case .failed(let reason): return reason
        case .cancelled: return "\(displayName) was cancelled."
        }
    }
}
