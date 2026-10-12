// TaxTriageAnalysisRunTool+Finalize.swift - The run-level artifacts of a TaxTriage run on the executor (phase P3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageAnalysisRunTool {
    /// The words of the bar while the finalize builds the viewer index, as the app's TaxTriage row has them.
    static let databaseStageMessage = "Building TaxTriage database\u{2026}"

    /// The finalize's share of the progress range, the descriptor's (W3). The engine moves the bar to 0.9
    /// and the viewer index takes it from there to the end.
    package var finalizeProgressShare: Double {
        NextflowWorkflowDescriptor.taxTriage.finalizeProgressShare
    }

    /// Phase P3. A result folder's launch already handed its step, with the digests of its outputs, to
    /// the root record. A batch root's samples each keep their own record, so the root names each
    /// completed sample's outputs with the digest and size that record took, and hashes nothing again
    /// (S2). Those the cleanup then removes drop out of the run level, which names only kept files.
    ///
    /// A result in a project or a batch root then gets its viewer index in process, `taxtriage.sqlite`
    /// through the index builder the executor was given, with the build's steps and the recorded
    /// removal step of its cleanup, which keeps `top/` (2.8 T5 and row 258, B12 M2) and names each
    /// removed file with the digest a record already holds (T5 as amended in 2.9). A plain `--output`
    /// keeps its folder as the command has always left it, with no index and no cleanup, as a Kraken2
    /// result outside a project does. An index that cannot be built leaves a warning and the result,
    /// since the viewer builds the index when the result opens.
    package func finalize(
        _ units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        var finalization = AnalysisRunFinalization()
        if context.layout == .batchRoot {
            finalization.recordedFiles = units
                .filter { $0.outcome.result != nil }
                .compactMap { ProvenanceRecorder.loadEnvelope(from: $0.directory)?.outputs }
                .flatMap { $0 }
        }
        guard context.layout != .singleFolder else { return finalization }

        context.progress(0, Self.databaseStageMessage)
        do {
            // T5 as amended. The cleanup names each file it removes with the digest a record already
            // holds, the steps the units handed to the root record or a batch sample's own record,
            // which the cleanup reads in the sample's folder. It hashes nothing.
            let recorded = context.recordedSteps.flatMap { $0.inputs + $0.outputs }
            let index = try await context.buildIndex(recordedFiles: recorded)
            finalization.outputs += index.outputs
            finalization.steps += index.steps
            finalization.warnings += index.warnings
        } catch {
            finalization.warnings.append(
                "The viewer index could not be built: \(error.localizedDescription). The viewer builds it when the result opens."
            )
        }
        context.progress(1, Self.databaseStageMessage)
        return finalization
    }
}
