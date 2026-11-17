// FASTQDialogKeepUncheckedSamplesTests.swift - The dialog offers Keep Unchecked Samples exactly for a kit preflight can refuse
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-SATKIT (SATKIT-3), ruling BIO-SATKIT-FLUIDIGM item 3. Preflight refuses a search of the
// read bases whose kit the chance check cannot judge, unless the person keeps the unchecked samples. The CLI has
// --keep-unchecked-samples, so the dialog must reach the same runs (CLI-EQUIVALENCE). It shows the box exactly when
// preflight's own predicate says the kit can be refused, and a ticked box reaches the command the run records.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class FASTQDialogKeepUncheckedSamplesTests: XCTestCase {
    /// The Demultiplex Barcodes tool with the dialog's defaults: Built-In Kit, Cutadapt, error rate 0.15, Both Ends.
    private func dialog() -> FASTQOperationDialogState {
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )
        state.selectTool(.demultiplexBarcodes)
        return state
    }

    /// QA's 384 kit as a definition file (`DemultiplexSaturatedKitTests.qa384Barcodes` in the Workflow tests, which this
    /// target cannot see): 192 barcodes of 4 bases and 192 of 5, prefix free, about 0.94 of reads by chance.
    private func qa384Definition() throws -> URL {
        let folder = try TestTempDirectory.make(prefix: "dialog-keep-unchecked")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        let letters = Array("ACGT")
        let fours = (0..<256).map { value in String((0..<4).map { letters[(value >> (2 * (3 - $0))) & 3] }) }
        let fives = Array(fours.suffix(64).flatMap { prefix in letters.map { prefix + String($0) } }.prefix(192))
        let rows = (Array(fours.prefix(192)) + fives).enumerated().map {
            "BC\(String(format: "%03d", $0.offset + 1)),\($0.element)"
        }
        let url = folder.appendingPathComponent("QA 384.csv")
        try (["id,sequence"] + rows).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The request Run builds, the choice it carries, and the arguments `lungfish-cli` is given.
    private func launch(_ state: FASTQOperationDialogState) throws -> (keep: Bool?, arguments: [String]) {
        state.prepareForRun()
        let launch = try XCTUnwrap(state.pendingLaunchRequest)
        guard case .derivative(.demultiplex(_, _, _, _, _, _, _, _, _, _, _, let keep), _, _) = launch else {
            XCTFail("the dialog builds a demultiplex request, got \(launch)")
            throw CocoaError(.featureUnsupported)
        }
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(
            for: launch, outputTargetPath: "/tmp/demux-out"
        )
        return (keep, invocation.arguments)
    }

    /// The box shows for the built-in Fluidigm Access Array kit at the default 0.15 and for QA's 384 definition, which
    /// preflight refuses, and not for ONT Native Barcoding 24 (id `ont-nbd104-114`), which it never refuses. An answer
    /// for other settings is never shown, so a changed kit hides the box until its own answer comes.
    func testTheBoxShowsExactlyForTheKitsPreflightCanRefuse() async throws {
        let state = dialog()
        XCTAssertEqual(state.demultiplexEngine, .cutadapt)
        XCTAssertEqual(state.demultiplexErrorRate, 0.15)
        state.demultiplexBarcodeSource = .builtinKit
        state.demultiplexKitID = "fluidigm-access-array"
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(
            state.showsDemultiplexKeepUncheckedSamples,
            "fluidigm-access-array at 0.15 shows no box, so the dialog refuses a run the CLI can make"
        )

        state.demultiplexKitID = BarcodeKitRegistry.ontNativeBarcoding24.id
        XCTAssertFalse(state.showsDemultiplexKeepUncheckedSamples, "the Fluidigm answer shows for another kit")
        await state.refreshDemultiplexChanceCheck()
        XCTAssertFalse(state.showsDemultiplexKeepUncheckedSamples, "ONT Native Barcoding 24 shows the box")

        state.demultiplexBarcodeSource = .customDefinition
        state.setAuxiliaryInput(try qa384Definition(), for: .barcodeDefinition)
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(state.showsDemultiplexKeepUncheckedSamples, "QA's 384 definition shows no box")

        state.demultiplexEngine = .exactBareBarcode
        await state.refreshDemultiplexChanceCheck()
        XCTAssertFalse(state.showsDemultiplexKeepUncheckedSamples, "Exact Bare Barcode has no chance check to refuse")
    }

    /// A ticked box reaches the request, the command the Operations row records, and the CLI's own flag, so the recorded
    /// command reproduces the run. An unticked box, or a ticked box the chosen kit does not show, writes no flag.
    func testATickedBoxReachesTheRecordedCommand() async throws {
        let state = dialog()
        state.demultiplexKitID = "fluidigm-access-array"
        await state.refreshDemultiplexChanceCheck()
        state.demultiplexChanceCheck.keepsUncheckedSamples = true
        var run = try launch(state)
        XCTAssertEqual(run.keep, true, "the ticked box is not in the request")
        XCTAssertTrue(run.arguments.contains("--keep-unchecked-samples"), "\(run.arguments)")
        XCTAssertFalse(run.arguments.contains("--engine"), "the default engine still asks the route owner")
        let command = try FastqDemultiplexSubcommand.parse(Array(run.arguments.dropFirst()))
        XCTAssertTrue(command.keepUncheckedSamples, "the CLI does not read the flag the dialog wrote")

        state.demultiplexChanceCheck.keepsUncheckedSamples = false
        run = try launch(state)
        XCTAssertNil(run.keep)
        XCTAssertFalse(run.arguments.contains("--keep-unchecked-samples"), "\(run.arguments)")

        state.demultiplexChanceCheck.keepsUncheckedSamples = true
        state.demultiplexKitID = BarcodeKitRegistry.ontNativeBarcoding24.id
        await state.refreshDemultiplexChanceCheck()
        run = try launch(state)
        XCTAssertNil(run.keep, "a box the kit does not show reached the run")
        XCTAssertFalse(run.arguments.contains("--keep-unchecked-samples"), "\(run.arguments)")
    }
}
