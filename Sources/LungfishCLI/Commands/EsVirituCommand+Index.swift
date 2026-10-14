// EsVirituCommand+Index.swift - Builds esviritu.sqlite in process for the analysis run executor's finalize
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// The viewer index of an EsViritu result, built in process over the `build-db esviritu` core
/// (plan decision E6), so a new batch opens on its database and never needs a lazy build.
///
/// The core runs as `lungfish-cli build-db esviritu <root> --force` would, with its cleanup, and its
/// record names that command. It writes no record at the result root, because the executor writes
/// the root record last (risk R8), and its steps, the BAM relocation (E7), the samtools passes and
/// the database build, join the root record through the request as each ends whole (2.9 R6, lane
/// S33), so a cancel inside the core keeps the steps that ended. The core's own
/// lines and warnings become info lines of the run, because the app's EsViritu runs have never
/// shown them on the row. A build that throws leaves the finalize to warn, as the app does.
struct EsVirituResultIndexing: AnalysisResultIndexing {
    enum IndexingError: Error, LocalizedError {
        case notEsViritu(AnalysisToolID)

        var errorDescription: String? {
            switch self {
            case .notEsViritu(let toolID):
                return "The EsViritu index builder cannot index \(toolID.rawValue) results."
            }
        }
    }

    /// The command's cancel request, which can report a SIGTERM before the run's task is cancelled, as the
    /// executor's `cancelRequested` does. The core reads it beside the task's cancel (2.8 row 266, lane S33).
    var cancelRequested: @Sendable () -> Bool = { false }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        guard request.toolID == .esviritu else {
            throw IndexingError.notEsViritu(request.toolID)
        }
        let sink = BuildDbEventSink(
            progress: { _, _ in },
            text: { line in request.log(.info, line) },
            textWarning: { line in request.log(.info, line) },
            warning: { line in request.log(.info, line) },
            step: { request.recordStep($0) },
            cancelRequested: cancelRequested
        )
        let built = try await BuildDbCommand.EsVirituSubcommand.buildDatabase(
            in: request.resultDirectory,
            options: BuildDbRunOptions(force: true, globalOptions: try GlobalOptions.parse([]), writesFolderRecord: false),
            events: sink
        )
        let steps = built.record?.steps ?? []
        return AnalysisResultIndex(
            outputs: [AnalysisRunOutput(url: built.databaseURL, format: .sqlite)],
            steps: steps
        )
    }
}

extension EsVirituCommand.DetectSubcommand {
    /// The index builder `esviritu detect` gives the analysis run executor. Its core reads the command's cancel
    /// request beside the run's task, so a SIGTERM counted before the task is cancelled stops it at its next check
    /// (2.8 row 266, lane S33).
    static func resultIndexer(cancelRequested: @escaping @Sendable () -> Bool) -> EsVirituResultIndexing {
        EsVirituResultIndexing(cancelRequested: cancelRequested)
    }
}
