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

    /// A custom dual-index definition of two pairs of 8 bases (`DemultiplexSaturatedKitTests.dualPairs` in the Workflow
    /// tests holds 96, which this target cannot see). With Both Ends and no sample sheet cutadapt searches each pair as
    /// `i7...i5` with neither side anchored, so preflight refuses it whatever the number of pairs.
    private func dualDefinition() throws -> URL {
        let folder = try TestTempDirectory.make(prefix: "dialog-keep-unchecked-dual")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        let url = folder.appendingPathComponent("Dual Two.csv")
        try "S1,ATTACTCG,TATAGCCT\nS2,TCCGGAGA,ATAGAGGC\n".write(to: url, atomically: true, encoding: .utf8)
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

    /// The box shows for the built-in Fluidigm Access Array kit at the default 0.15 and at error 0, for QA's 384 definition,
    /// and for a custom dual-index definition at Both Ends with no sample sheet at error 0 and 0.15, which preflight
    /// refuses, and not for ONT Native Barcoding 24 (id `ont-nbd104-114`), which it never refuses. An answer for other
    /// settings is never shown, so a changed kit hides the box until its own answer comes.
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

        // A kit whose lines have no anchored side is refused at every error rate (BIO-SATKIT-ANYWHERE items 1 to 3), though
        // its share is under 0.5 at error 0. The Fluidigm kit gets the words of a kit searched anywhere, the dual definition
        // the words of pairs searched anywhere, and the box shows for both.
        state.demultiplexBarcodeSource = .builtinKit
        state.demultiplexKitID = "fluidigm-access-array"
        state.demultiplexErrorRate = 0
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(
            state.showsDemultiplexKeepUncheckedSamples,
            "fluidigm-access-array at error 0 shows no box, so the dialog refuses a run the CLI can make"
        )

        state.demultiplexBarcodeSource = .customDefinition
        state.setAuxiliaryInput(try dualDefinition(), for: .barcodeDefinition)
        XCTAssertEqual(state.demultiplexLocation, "bothends")
        for errorRate in [0.0, 0.15] {
            state.demultiplexErrorRate = errorRate
            await state.refreshDemultiplexChanceCheck()
            XCTAssertTrue(
                state.showsDemultiplexKeepUncheckedSamples,
                "a custom dual definition at Both Ends with no sample sheet shows no box at error \(errorRate)"
            )
        }

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

    /// The caption under the box says what the refusal says, since a person who ticks the box never reads the refusal
    /// (WORDS-UX W11, ruling R1). The built-in Fluidigm Access Array kit, which cutadapt searches anywhere in the read, gets
    /// a caption that names the two routes made for it, ONT Fluidigm Sample Split and the engine Read Names. Every other
    /// kit, a custom dual definition and QA's 384 definition here, gets the first caption, which names no Fluidigm tool.
    func testTheFluidigmKitGetsTheCaptionThatNamesItsRoutes() async throws {
        let state = dialog()
        state.demultiplexBarcodeSource = .builtinKit
        state.demultiplexKitID = "fluidigm-access-array"
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(state.showsDemultiplexKeepUncheckedSamples, "fluidigm-access-array at 0.15 shows no box")
        let fluidigm = state.demultiplexKeepUncheckedSamplesCaptionForEngine
        XCTAssertEqual(fluidigm, FASTQOperationDialogState.demultiplexKeepUncheckedSamplesFluidigmCaption)
        XCTAssertTrue(fluidigm.contains("ONT Fluidigm Sample Split"), fluidigm)
        XCTAssertTrue(fluidigm.contains("Read Names"), fluidigm)

        state.demultiplexBarcodeSource = .customDefinition
        state.setAuxiliaryInput(try dualDefinition(), for: .barcodeDefinition)
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(state.showsDemultiplexKeepUncheckedSamples, "a custom dual definition shows no box")
        let dual = state.demultiplexKeepUncheckedSamplesCaptionForEngine
        XCTAssertEqual(dual, FASTQOperationDialogState.demultiplexKeepUncheckedSamplesCaption)
        XCTAssertFalse(dual.contains("Fluidigm"), dual)

        state.setAuxiliaryInput(try qa384Definition(), for: .barcodeDefinition)
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(state.showsDemultiplexKeepUncheckedSamples, "QA's 384 definition shows no box")
        let qa = state.demultiplexKeepUncheckedSamplesCaptionForEngine
        XCTAssertEqual(qa, FASTQOperationDialogState.demultiplexKeepUncheckedSamplesCaption)
        XCTAssertFalse(qa.contains("Fluidigm"), qa)
    }
}
