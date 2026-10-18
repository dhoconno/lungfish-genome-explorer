// PrimerDesignCLIGUIParityReplayTests+PrimalScheme3.swift - The PrimalScheme3 design in the app against the command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 M1 (3), PLAN row 12.16 (A67-ENGINES), item 2 of row A67-next of the A67 review, BIO risk BR13,
// C4 of 2.10 and 2.9 O5. The case runs the class's three sides on one input alignment and the real `primalscheme3` of
// the managed environment.
//
// - Side A is the app's route, the class's `sideA` with the engine named, which runs the dialog's command through
//   `CLIPrimerDesignRunner` (lane 12.17 M2). It ran the pipeline in process when lane 12.16 proved A against C.
// - Side C is the row with the command built from the same dialog and the built `lungfish-cli` on its arguments, the
//   class's `sideC` with the engine named.
// - Side C' is the harness's replay of that command.
//
// A against C and C against C' declare nothing (C4), under OutputEquivalence.MaskPolicy.primerAnalysis. The fixture
// holds one alignment, so no two input files tie on their blanked name and text (Finding 5 of the A67 continuation).

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

extension PrimerDesignCLIGUIParityReplayTests {
    nonisolated static let alignmentName = "alignment.fasta"

    func testThePrimalScheme3RowWritesWhatTheInProcessRunWroteOnRealPrimalScheme3() async throws {
        let conda = CondaManager.shared
        do {
            _ = try await conda.toolPath(name: "primalscheme3", environment: "primalscheme3")
        } catch {
            try ToolAvailability.skipOrFail("primalscheme3 is not installed in the managed environment: \(error)")
        }
        let environment = ["LUNGFISH_CONDA_ROOT": conda.rootPrefix.path]
        let harness = RouteParityHarness(
            cliBinary: cli, kind: .bundle, masks: .primerAnalysis, replayTimeout: .seconds(600),
            environment: { _ in environment }
        )
        let result = try await harness.assertParity(
            Case.primalScheme3,
            declared: Self.declared,
            in: scratch.appendingPathComponent(Case.primalScheme3.rawValue, isDirectory: true),
            fixture: { root in try Self.writeAlignmentFixture(root) },
            sideA: { root in
                await self.sideA(
                    root, engine: .primalScheme, input: Self.alignmentName, cli: self.cli, environment: environment
                )
            },
            sideC: { root in await self.sideC(root, harness: harness, engine: .primalScheme, input: Self.alignmentName) }
        )
        let command = try XCTUnwrap(result.runs.c.outcome.recordedCommand, "side C records the row's command")
        XCTAssertTrue(command.hasPrefix("lungfish-cli primers design primalscheme3 "), command)
        // Side A runs in its own root, so its row's command names that root, and its record names that command.
        let commandA = try XCTUnwrap(result.runs.a.outcome.recordedCommand, "side A records the row's command")
        try Self.assertRecordedArgv(of: result.runs.a, is: RecordedCLICommand.arguments(of: commandA), cli: cli)
        try Self.assertRecordedArgv(of: result.runs.c, is: RecordedCLICommand.arguments(of: command), cli: cli)
        try Self.assertRecordedArgv(
            of: result.runs.cPrime, is: try XCTUnwrap(result.runs.cPrime.replayedArguments.first), cli: cli
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
    }

    // MARK: - The fixture

    /// One alignment of three rows of 1,500 bases from the class's fixed generator, each row but the first with two
    /// transitions of its own. The project has no `Analyses` folder, as in the Primer3 fixture, so the command makes it
    /// on every side (A67-ANALYSES).
    static func writeAlignmentFixture(_ root: URL) throws {
        let reference = sequence(seed: 23, length: 1_500)
        let rows = [
            ("row-one", reference),
            ("row-two", transitions(of: reference, at: [310, 905])),
            ("row-three", transitions(of: reference, at: [620, 1_210])),
        ]
        let text = rows.map { ">\($0.0)\n" + wrapped($0.1) + "\n" }.joined()
        try text.write(to: root.appendingPathComponent(alignmentName), atomically: true, encoding: .utf8)
    }

    /// `sequence` with the base at each offset replaced by its transition partner (A and G, C and T).
    private static func transitions(of sequence: String, at offsets: [Int]) -> String {
        var letters = Array(sequence)
        let partner: [Character: Character] = ["A": "G", "G": "A", "C": "T", "T": "C"]
        for offset in offsets { letters[offset] = partner[letters[offset]] ?? letters[offset] }
        return String(letters)
    }
}
