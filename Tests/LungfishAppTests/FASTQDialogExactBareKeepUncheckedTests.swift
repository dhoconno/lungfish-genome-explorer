// FASTQDialogExactBareKeepUncheckedTests.swift - The dialog offers Keep Unchecked Samples for Exact Bare on barcodes in the names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17 lane DEMUX-EXACTBARE-NAMES (item 2), ruling BIO-DEMUX-THREE item 7. Preflight refuses an Exact Bare
// Barcode run whose read names carry two or more of the kit's barcodes, unless the person keeps the unchecked samples. The CLI
// has --keep-unchecked-samples, so the dialog must reach the same runs (CLI-EQUIVALENCE). With Exact Bare the box shows exactly
// when preflight's own predicate says the names of a chosen input carry the barcodes, and a ticked box reaches the command.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI

@MainActor
final class FASTQDialogExactBareKeepUncheckedTests: XCTestCase {
    private static let twelve = ["ATTACTCG", "TCCGGAGA", "CGCTCATT", "GAGATTCC", "ATTCAGAA", "GAATTCGT", "CTGAAGCT",
                                 "TAATGCGC", "CGGCTATG", "TCCGCGAA", "TCTCGCGC", "AGCGATAG"]

    /// 2,000 reads of 150 seeded random bases whose names carry the comment `comment(i)`, or none when it gives nil, and the
    /// 12 barcodes as a definition with no `# kit:` line.
    private func files() throws -> (indexed: URL, plain: URL, definition: URL) {
        let folder = try TestTempDirectory.make(prefix: "dialog-exactbare-keep")
        addTeardownBlock { TestTempDirectory.cleanup(folder) }
        func write(_ name: String, comment: (Int) -> String?) throws -> URL {
            var state: UInt64 = 17
            let letters = Array("ACGT")
            var text = ""
            for index in 0..<2_000 {
                let bases = String((0..<150).map { _ -> Character in
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return letters[Int((state >> 33) % 4)]
                })
                let header = comment(index).map { "r\(index) \($0)" } ?? "r\(index)"
                text += "@\(header)\n\(bases)\n+\n\(String(repeating: "I", count: 150))\n"
            }
            let url = folder.appendingPathComponent(name)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let indexed = try write("indexed.fastq") { "1:N:0:\(Self.twelve[$0 % 2])" }
        let plain = try write("plain.fastq") { _ in nil }
        let definition = folder.appendingPathComponent("Twelve.csv")
        let rows = Self.twelve.enumerated().map { "BC\(String(format: "%02d", $0.offset + 1)),\($0.element)" }
        try (["id,sequence"] + rows).joined(separator: "\n").appending("\n").write(to: definition, atomically: true, encoding: .utf8)
        return (indexed, plain, definition)
    }

    /// The Demultiplex Barcodes tool on `input` with the definition and Exact Bare Barcode chosen.
    private func dialog(_ input: URL, definition: URL) -> FASTQOperationDialogState {
        let state = FASTQOperationDialogState(initialCategory: .demultiplexing, selectedInputURLs: [input])
        state.selectTool(.demultiplexBarcodes)
        state.demultiplexBarcodeSource = .customDefinition
        state.setAuxiliaryInput(definition, for: .barcodeDefinition)
        state.demultiplexEngine = .exactBareBarcode
        return state
    }

    /// The request Run builds, the choice it carries, and the arguments `lungfish-cli` is given.
    private func launch(_ state: FASTQOperationDialogState) throws -> (keep: Bool?, arguments: [String]) {
        state.prepareForRun()
        let launch = try XCTUnwrap(state.pendingLaunchRequest)
        guard case .derivative(.demultiplex(_, _, _, _, _, _, _, _, _, _, _, _, _, let keep), _, _) = launch else {
            XCTFail("the dialog builds a demultiplex request, got \(launch)")
            throw CocoaError(.featureUnsupported)
        }
        let invocation = try FASTQOperationCLIInvocationBuilder().buildInvocation(for: launch, outputTargetPath: "/tmp/demux-out")
        return (keep, invocation.arguments)
    }

    /// The box shows with Exact Bare for reads whose names carry two of the barcodes, with its own caption, and not for reads
    /// whose names carry no index, nor with Cutadapt, whose chance check judges a list of 12 barcodes of 8 bases.
    func testTheBoxShowsWithExactBareExactlyWhenTheReadNamesCarryTheKitsBarcodes() async throws {
        let (indexed, plain, definition) = try files()
        let state = dialog(indexed, definition: definition)
        await state.refreshDemultiplexChanceCheck()
        XCTAssertTrue(state.showsDemultiplexKeepUncheckedSamples, "the names carry two barcodes and the box is missing")
        XCTAssertEqual(state.demultiplexKeepUncheckedSamplesCaptionForEngine,
                       FASTQOperationDialogState.demultiplexExactBareKeepUncheckedSamplesCaption)

        state.demultiplexEngine = .cutadapt
        XCTAssertFalse(state.showsDemultiplexKeepUncheckedSamples, "the Exact Bare answer shows for Cutadapt")
        await state.refreshDemultiplexChanceCheck()
        XCTAssertFalse(state.showsDemultiplexKeepUncheckedSamples, "Cutadapt can judge 12 barcodes of 8 bases")

        let other = dialog(plain, definition: definition)
        await other.refreshDemultiplexChanceCheck()
        XCTAssertFalse(other.showsDemultiplexKeepUncheckedSamples, "names with no index show the box")
    }

    /// A ticked box reaches the request, the command the Operations row records with `--engine exact-bare`, and the CLI's own
    /// flag. An unticked box writes no flag.
    func testATickedBoxReachesTheRecordedCommandOfAnExactBareRun() async throws {
        let (indexed, _, definition) = try files()
        let state = dialog(indexed, definition: definition)
        await state.refreshDemultiplexChanceCheck()
        state.demultiplexChanceCheck.keepsUncheckedSamples = true
        var run = try launch(state)
        XCTAssertEqual(run.keep, true, "the ticked box is not in the request")
        XCTAssertTrue(run.arguments.contains("--keep-unchecked-samples"), "\(run.arguments)")
        let engine = try XCTUnwrap(run.arguments.firstIndex(of: "--engine"), "\(run.arguments)")
        XCTAssertEqual(run.arguments[engine + 1], "exact-bare")
        let command = try FastqDemultiplexSubcommand.parse(Array(run.arguments.dropFirst()))
        XCTAssertTrue(command.keepUncheckedSamples, "the CLI does not read the flag the dialog wrote")

        state.demultiplexChanceCheck.keepsUncheckedSamples = false
        run = try launch(state)
        XCTAssertNil(run.keep)
        XCTAssertFalse(run.arguments.contains("--keep-unchecked-samples"), "\(run.arguments)")
    }
}
