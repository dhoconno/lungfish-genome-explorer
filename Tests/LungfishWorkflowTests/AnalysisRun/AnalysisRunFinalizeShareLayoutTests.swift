// AnalysisRunFinalizeShareLayoutTests.swift - The executor reads a finalize share that depends on the plan's layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

/// A tool whose finalize share depends on the layout of its plan (W1 and Q-U33 of Phase 2.10), over
/// the fake that runs the units and the finalize, so a test sees what the executor read for each.
private struct LayoutShareTool: AnalysisRunTool {
    typealias Unit = FakeUnitScript
    typealias UnitResult = URL

    var base: FakeAnalysisRunTool
    /// The share of each layout, 0 for a layout not named.
    var shares: [AnalysisRunLayout: Double]

    var identity: AnalysisRunIdentity { base.identity }
    var terminalPolicy: AnalysisRunTerminalPolicy { base.terminalPolicy }

    func finalizeProgressShare(for layout: AnalysisRunLayout) -> Double {
        shares[layout] ?? 0
    }

    func plan(_ request: AnalysisRunRequest, context: AnalysisRunPlanningContext) async throws -> AnalysisRunPlan<FakeUnitScript> {
        try await base.plan(request, context: context)
    }

    func run(_ unit: AnalysisRunUnit<FakeUnitScript>, context: AnalysisRunUnitContext) async throws -> AnalysisUnitOutcome<URL> {
        try await base.run(unit, context: context)
    }

    func finalize(_ units: [AnalysisUnitReport<URL>], context: AnalysisRunFinalizeContext) async throws -> AnalysisRunFinalization {
        try await base.finalize(units, context: context)
    }
}

/// W3 of Phase 2.9 gave a tool one finalize share for every layout, so a TaxTriage run to a plain
/// `--output` reserved the last tenth of its bar for a finalize that returns at once and ended at 90
/// percent. The executor now asks the tool for the share of the layout its plan chose (U38 M2).
@Suite("Finalize share by layout")
struct AnalysisRunFinalizeShareLayoutTests {
    /// The progress fractions of one run of a single unit that reports 0.5 and 1 and a finalize that
    /// reports 0, 0.5 and 1 of its own share, laid out as `layout`.
    private static func fractions(layout: AnalysisRunLayout, shares: [AnalysisRunLayout: Double]) async throws -> [Double] {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var base = FakeAnalysisRunTool(probe: FakeToolProbe())
        base.layout = layout
        base.finalizeProgress = [0, 0.5, 1]
        base.units = [AnalysisRunPlannedUnit(label: "s1", value: .progress([0.5, 1]))]
        let tool = LayoutShareTool(base: base, shares: shares)

        _ = await AnalysisRunExecutor.unsigned.execute(
            tool,
            fixture.request(groupsSamples: layout == .batchRoot),
            events: recorder.events
        )

        return recorder.snapshot.compactMap { line -> Double? in
            if case .progress(let fraction, _)? = line.event { return fraction }
            return nil
        }
    }

    private static func expect(_ seen: [Double], equals expected: [Double]) {
        #expect(seen.count == expected.count, "\(seen)")
        for (value, wanted) in zip(seen, expected) {
            #expect(abs(value - wanted) < 1e-9, "\(seen)")
        }
    }

    @Test("A layout with no share gives its units the whole bar, and the finalize reports at the end")
    func layoutWithNoShareEndsTheUnitsAtTheEndOfTheBar() async throws {
        let seen = try await Self.fractions(layout: .singleFolder, shares: [.singleFolder: 0, .batchRoot: 0.1])

        Self.expect(seen, equals: [0, 0.5, 1, 1, 1, 1])
    }

    @Test("A layout with a share keeps the units below it and hands the rest to the finalize")
    func layoutWithAShareKeepsItsFinalizeAtTheEndOfTheBar() async throws {
        let seen = try await Self.fractions(layout: .batchRoot, shares: [.singleFolder: 0, .batchRoot: 0.1])

        Self.expect(seen, equals: [0, 0.45, 0.9, 0.9, 0.95, 1])
    }

    @Test("A tool that does not override the layout's share keeps the share it states for every layout")
    func defaultShareIsTheSameForEveryLayout() {
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.finalizeProgressShare = 0.1

        for layout in AnalysisRunLayout.allCases {
            #expect(tool.finalizeProgressShare(for: layout) == 0.1, "\(layout)")
        }
    }

    @Test("TaxTriage keeps the descriptor's tenth for a project or batch result and takes none for a plain --output")
    func taxTriageTakesNoShareForAPlainOutput() {
        let request = TaxTriageRunRequest(
            settings: TaxTriageConfig(samples: [], outputDirectory: URL(fileURLWithPath: "/tmp/taxtriage-share-unused"))
        )
        let tool = TaxTriageAnalysisRunTool(request: request)

        #expect(NextflowWorkflowDescriptor.taxTriage.finalizeProgressShare == 0.1, "W3 keeps the project and batch share")
        #expect(tool.finalizeProgressShare == 0.1)
        #expect(tool.finalizeProgressShare(for: .singleFolder) == 0, "a plain --output has no finalize to keep a tenth for")
        #expect(tool.finalizeProgressShare(for: .sharedBatchRoot) == 0.1)
        #expect(tool.finalizeProgressShare(for: .batchRoot) == 0.1)
    }
}
