// TaxTriageAnalysisRunTool+Finalize.swift - The run-level artifacts of a TaxTriage run on the executor (phase P3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageAnalysisRunTool {
    /// Phase P3. The lane's first milestone runs no unit, so the finalize is refused with
    /// ``TaxTriageRunRefusal/notRunnableYet`` too. Milestone 2 deletes the refusal and milestone 3
    /// writes the viewer index here.
    package func finalize(
        _ units: [AnalysisUnitReport<TaxTriageUnitResult>],
        context: AnalysisRunFinalizeContext
    ) async throws -> AnalysisRunFinalization {
        throw TaxTriageRunRefusal.notRunnableYet
    }
}
