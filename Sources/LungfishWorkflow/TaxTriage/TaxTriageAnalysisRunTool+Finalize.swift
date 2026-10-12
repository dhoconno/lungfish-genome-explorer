// TaxTriageAnalysisRunTool+Finalize.swift - The run-level artifacts of a TaxTriage run on the executor (phase P3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageAnalysisRunTool {
    /// Phase P3. A result folder's launch already handed its step, with the digests of its outputs,
    /// to the root record. A batch root's samples each keep their own record, so the root names each
    /// completed sample's outputs with the digest and size that record took, and hashes nothing again
    /// (S2). Milestone 3 builds the viewer index over A1's core here, with the recorded removal step
    /// of `build-db taxtriage` (T5, B12 M2) and the finalize's share of the bar (W3).
    package func finalize(
        _ units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        guard context.layout == .batchRoot else { return AnalysisRunFinalization() }
        let recordedFiles = units
            .filter { $0.outcome.result != nil }
            .compactMap { ProvenanceRecorder.loadEnvelope(from: $0.directory)?.outputs }
            .flatMap { $0 }
        return AnalysisRunFinalization(recordedFiles: recordedFiles)
    }
}
