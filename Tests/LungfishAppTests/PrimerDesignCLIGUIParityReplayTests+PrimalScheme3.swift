// PrimerDesignCLIGUIParityReplayTests+PrimalScheme3.swift - The PrimalScheme3 design in the app against the command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 M1 (3), PLAN row 12.16 (A67-ENGINES), item 2 of row A67-next of the A67 review, BIO risk BR13,
// C4 of 2.10 and 2.9 O5. The case runs the class's three sides on one input alignment and the real `primalscheme3` of
// the managed environment.
//
// - Side A is the request `PrimerDesignDialogPresenter.run` builds from the dialog for PrimalScheme3 (its visible
//   options and `PrimalScheme3DesignRequest`) on `PrimalScheme3DesignPipeline().run(request:)`, the call
//   `PrimerDesignOperation.start` makes. Its invocation records `CommandLine.arguments` as the presenter does, so lane
//   12.17's change of side A's argv applies here as well.
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
            sideA: { root in await self.primalScheme3SideA(root) },
            sideC: { root in await self.sideC(root, harness: harness, engine: .primalScheme, input: Self.alignmentName) }
        )
        let command = try XCTUnwrap(result.runs.c.outcome.recordedCommand, "side C records the row's command")
        XCTAssertTrue(command.hasPrefix("lungfish-cli primers design primalscheme3 "), command)
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
    /// transitions of its own, and the project's `Analyses` folder, as the Primer3 fixture holds it.
    static func writeAlignmentFixture(_ root: URL) throws {
        let reference = sequence(seed: 23, length: 1_500)
        let rows = [
            ("row-one", reference),
            ("row-two", transitions(of: reference, at: [310, 905])),
            ("row-three", transitions(of: reference, at: [620, 1_210])),
        ]
        let text = rows.map { ">\($0.0)\n" + wrapped($0.1) + "\n" }.joined()
        try text.write(to: root.appendingPathComponent(alignmentName), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Analyses", isDirectory: true), withIntermediateDirectories: true
        )
    }

    /// `sequence` with the base at each offset replaced by its transition partner (A and G, C and T).
    private static func transitions(of sequence: String, at offsets: [Int]) -> String {
        var letters = Array(sequence)
        let partner: [Character: Character] = ["A": "G", "G": "A", "C": "T", "T": "C"]
        for offset in offsets { letters[offset] = partner[letters[offset]] ?? letters[offset] }
        return String(letters)
    }

    // MARK: - Side A

    /// Side A. The PrimalScheme3 request the presenter builds from the dialog (`PrimerDesignDialogPresenter.swift`,
    /// the visible options of the PrimalScheme branch and the `.primalScheme` request), on the pipeline
    /// `PrimerDesignOperation.start` runs.
    private func primalScheme3SideA(_ root: URL) async -> RouteParitySideOutcome {
        do {
            let state = await Self.dialog(in: root, engine: .primalScheme, input: Self.alignmentName)
            let destination = try state.validatedDestinationURL(createParent: true)
            let runtime = ProvenanceRuntimeIdentity()
            let options = try state.primalSchemeOptions()
            let executable = state.primalschemeExecutableURL
            let visibleOptions: [String: ParameterValue] = [
                "analysisName": .string(state.analysisName),
                "engine": .string(state.engine.rawValue),
                "interface": .string("Lungfish PCR Primer Design"),
                "projectPath": .string(root.path),
                "minimumBaseFrequency": .number(options.minimumBaseFrequency),
                "minimumBaseFrequencySource": .string("visible GUI control"),
                "selectionAlgorithm": .string(options.selectionAlgorithm.rawValue),
                "nativeExecutablePath": executable.map { .string($0.path) } ?? .null,
                "nativeExecutableSource": .string(executable == nil ? "managed-runtime" : "user-selected-local-executable"),
                "legacySalvage": .boolean(state.legacySalvageEnabled),
                "gapCompletionParent": state.gapCompletionParentURL.map { .string($0.path) } ?? .null,
                "gapExpansion": .boolean(state.gapExpansionEnabled),
            ]
            let invocation = PrimerAnalysisWrapperInvocation(
                argv: CommandLine.arguments, callerVersion: runtime.appVersion ?? WorkflowRun.currentAppVersion,
                explicitOptions: visibleOptions, runtimeIdentity: runtime
            )
            let request = PrimalScheme3DesignRequest(
                inputURLs: state.inputURLs, destinationURL: destination, options: options, grouping: state.grouping,
                invocation: invocation, executableURL: executable,
                expectedInputChecksums: state.inputSummaries.mapValues(\.checksumSHA256)
            )
            _ = try await PrimalScheme3DesignPipeline().run(request: request)
            return RouteParitySideOutcome(end: .completed, detail: "Primer analysis saved.")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }
}
