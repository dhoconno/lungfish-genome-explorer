// ClassifyCommand+Index.swift - The viewer index a Kraken2 run builds in process, and the exit codes its refusals carry
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishIO
import LungfishWorkflow

/// Builds `kraken2.sqlite` for a Kraken2 run's finalize, in process, through the `build-db
/// kraken2` core (decision E6), so a new result never needs a build at first view.
///
/// A batch root indexes the sample folders its manifest lists, the completed samples, as the app
/// has always passed them with `--sample-dir`. A one-folder result indexes its own report. The core
/// writes no record at the root, because the executor writes the root record after the finalize,
/// and the core hands each step to that record through the request as the step ends whole (2.9
/// R6, lane S33), so a cancel inside the core keeps the steps that ended. The builder returns the
/// same steps, which the finalize records once each, by id.
struct Kraken2ResultIndexer: AnalysisResultIndexing {
    /// The command's cancel request, which can report a SIGTERM before the run's task is cancelled, as the
    /// executor's `cancelRequested` does. The core reads it beside the task's cancel (2.8 row 266, lane S33).
    var cancelRequested: @Sendable () -> Bool = { false }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        guard request.toolID == .kraken2 else {
            throw AnalysisRunError.noResultIndexer(request.toolID)
        }
        var sampleDirectories: [URL] = []
        if request.layout == .batchRoot,
           let manifest = MetagenomicsBatchResultStore.loadClassification(from: request.resultDirectory) {
            sampleDirectories = manifest.samples.map {
                request.resultDirectory.appendingPathComponent($0.resultDirectory, isDirectory: true)
            }
        }
        let options = BuildDbRunOptions(
            force: true,
            noCleanup: false,
            sampleDirectories: sampleDirectories,
            globalOptions: try GlobalOptions.parse([]),
            writesFolderRecord: false
        )
        let events = BuildDbEventSink(
            progress: { _, _ in },
            text: { request.log(.info, $0) },
            textWarning: { request.log(.warning, $0) },
            warning: { request.log(.warning, $0) },
            step: { request.recordStep($0) },
            cancelRequested: cancelRequested
        )
        let built = try await BuildDbCommand.Kraken2Subcommand.buildDatabase(
            in: request.resultDirectory,
            options: options,
            events: events
        )
        let steps = built.record?.steps ?? []
        return AnalysisResultIndex(
            outputs: [AnalysisRunOutput(url: built.databaseURL, role: .index)],
            steps: steps
        )
    }
}

/// A refusal of the command carries its exit code into the analysis run, so a run that the plan
/// refuses ends as the command always has, 3 for an input error and 126 for a missing dependency.
extension CLIError: AnalysisRunExitCoding {
    var analysisRunExitCode: Int32 { exitCode.rawValue }
}
