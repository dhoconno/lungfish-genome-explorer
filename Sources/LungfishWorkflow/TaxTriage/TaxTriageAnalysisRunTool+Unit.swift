// TaxTriageAnalysisRunTool+Unit.swift - One TaxTriage launch on the analysis run executor (phase P2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageAnalysisRunTool {
    /// Phase P2. The lane's first milestone plans TaxTriage on the executor and runs nothing, so every
    /// unit is refused with ``TaxTriageRunRefusal/notRunnableYet``. Milestone 2 replaces this body with
    /// the launch.
    package func run(
        _ unit: AnalysisRunUnit<TaxTriageRunUnit>,
        context: AnalysisRunUnitContext
    ) async throws -> AnalysisUnitOutcome<TaxTriageUnitResult> {
        throw TaxTriageRunRefusal.notRunnableYet
    }
}
