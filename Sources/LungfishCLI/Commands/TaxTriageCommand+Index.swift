// TaxTriageCommand+Index.swift - The viewer index a TaxTriage run builds in process, with its recorded cleanup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// Builds `taxtriage.sqlite` for a TaxTriage run's finalize, in process, through the `build-db
/// taxtriage` core (Phase 2.9 lane A2, as `Kraken2ResultIndexer` builds Kraken2's), so a new result
/// never needs a build at first view.
///
/// A result folder indexes its own reports, and a batch root the reports of each sample folder in it,
/// in byte order of their names (BIO 8). The cleanup is the executor's form of decision T5 of Phase
/// 2.8. It keeps `top/`, removes `count/`, the fastp FASTQ files and seven intermediate folders, and
/// its removal step comes after the build step in the steps this returns, so the root record names
/// the removal after the step that read what it removed (2.8 P1). The core writes no record at the
/// root, because the executor writes the root record after the finalize.
struct TaxTriageResultIndexer: AnalysisResultIndexing {
    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        guard request.toolID == .taxtriage else {
            throw AnalysisRunError.noResultIndexer(request.toolID)
        }
        let options = BuildDbRunOptions(
            force: true,
            noCleanup: false,
            globalOptions: try GlobalOptions.parse([]),
            writesFolderRecord: false
        )
        let events = BuildDbEventSink(
            progress: { _, _ in },
            text: { request.log(.info, $0) },
            textWarning: { request.log(.warning, $0) },
            warning: { request.log(.warning, $0) }
        )
        let built = try await BuildDbCommand.TaxTriageSubcommand.buildDatabase(
            in: request.resultDirectory,
            options: options,
            cleanup: .recordedRemoval,
            events: events
        )
        return AnalysisResultIndex(
            outputs: [AnalysisRunOutput(url: built.result.databaseURL, role: .index)],
            steps: (built.result.record?.steps ?? []) + (built.removal.map { [$0] } ?? [])
        )
    }
}
