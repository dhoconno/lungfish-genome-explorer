// ClassifierExtractionRefusedEstimateTests.swift — the Extract Reads sheet after a refused read-count estimate
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 2.12 lane 12.26, K12 (b) (UX ruling U-W1 to U-W3). The sheet is presented on a window with the real resolver,
/// over an EsViritu result whose BAM is missing (`bamNotFound`) or is a link out of the result (`bamOutsideResult`),
/// so the message, the count and the Extract state are read from the model the sheet shows.
@MainActor
final class ClassifierExtractionRefusedEstimateTests: XCTestCase {

    private var folders: [URL] = []
    private var captureOnly = false
    /// The sheet panel's content height and the height its content asks for, read after the estimate ended.
    private var panelContentHeight: CGFloat = 0
    private var panelFittingHeight: CGFloat = 0

    override func setUp() async throws {
        try await super.setUp()
        // Each case presents the sheet over a host window of its own, which no tearDown can reach.
        orderOutWindowsOpenedDuringTest()
        captureOnly = TaxonomyReadExtractionAction.shared.testingCaptureOnly
        TaxonomyReadExtractionAction.shared.testingCaptureOnly = false
    }

    override func tearDown() async throws {
        TaxonomyReadExtractionAction.shared.testingCaptureOnly = captureOnly
        for folder in folders { TestTempDirectory.cleanup(folder) }
        folders = []
        try await super.tearDown()
    }

    /// An EsViritu result of sample `sampleId`. With `linkedOut` its recorded BAM is a link to a file outside the result.
    private func makeResult(linkedOut: Bool, sampleId: String = "S1") throws -> URL {
        let recorded = "\(sampleId)/bams/\(sampleId).third.filt.sorted.bam"
        let root = try TestTempDirectory.make(prefix: "refused-estimate")
        folders.append(root)
        let resultPath = root.appendingPathComponent("esviritu.sqlite")
        try EsVirituDatabase.create(
            at: resultPath,
            rows: [EsVirituDetectionRow(
                sample: sampleId, virusName: "Test virus", description: nil, contigLength: 1_000, segment: nil,
                accession: "NC_000001.1", assembly: "ASM_S1", assemblyLength: 1_000, kingdom: nil,
                phylum: nil, tclass: nil, torder: nil, family: nil, genus: nil, species: nil, subspecies: nil,
                rpkmf: 1, readCount: 10, uniqueReads: 10, coveredBases: 900, meanCoverage: 5,
                avgReadIdentity: 0.99, pi: nil, filteredReadsInSample: 100,
                bamPath: linkedOut ? recorded : nil, bamIndexPath: linkedOut ? recorded + ".bai" : nil
            )],
            metadata: ["tool": "test"]
        )
        guard linkedOut else { return resultPath }
        let outside = try TestTempDirectory.make(prefix: "refused-estimate-outside")
        folders.append(outside)
        let outsideBAM = outside.appendingPathComponent("\(sampleId).third.filt.sorted.bam")
        try Data([0x1F, 0x8B]).write(to: outsideBAM)
        let link = root.appendingPathComponent(recorded)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideBAM)
        return resultPath
    }

    /// Presents the sheet over `resultPath` and returns its model once the estimate has ended in a message.
    private func presentAndWaitForTheEstimate(
        resultPath: URL, host: NSWindow, sampleId: String = "S1"
    ) async throws -> ClassifierExtractionDialogViewModel {
        let context = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: resultPath,
            selections: [ClassifierRowSelector(sampleId: sampleId, accessions: ["NC_000001.1"], taxIds: [])],
            suggestedName: "reads"
        )
        TaxonomyReadExtractionAction.shared.present(context: context, hostWindow: host)
        let sheet = try XCTUnwrap(host.attachedSheet, "the extraction sheet is attached to its host window")
        let controller = try XCTUnwrap(sheet.contentViewController as? NSHostingController<ClassifierExtractionDialog>)
        let model = controller.rootView.model
        for _ in 0..<300 where model.errorMessage == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // One pass of the run loop lets the sheet lay out the message, then the panel is measured against its content.
        try await Task.sleep(nanoseconds: 300_000_000)
        sheet.layoutIfNeeded()
        panelContentHeight = sheet.contentRect(forFrameRect: sheet.frame).height
        panelFittingHeight = controller.view.fittingSize.height
        host.endSheet(sheet)
        return model
    }

    private func makeHost() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    }

    /// The error text the sheet shows, with the words of the refusal.
    private func words(_ error: ClassifierExtractionError) throws -> String {
        try XCTUnwrap(error.errorDescription)
    }

    // MARK: - The sheet after a refusal (U-W1 to U-W3)

    /// The refusal's own words in full with no prefix, no read count, Extract off and no line limit. These tests
    /// fail at the base, where the sheet shows `Could not estimate read count: ` before the words, a count of 0 and
    /// Extract on (the M1 pins of the previous commit passed there).
    private func assertRefusalShown(
        _ model: ClassifierExtractionDialogViewModel, _ error: ClassifierExtractionError,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(model.errorMessage, try words(error), file: file, line: line)
        XCTAssertFalse(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, file: file, line: line)
        XCTAssertFalse(model.isPrimaryEnabled, "the run would only show the same refusal", file: file, line: line)
        XCTAssertFalse(model.showsReadEstimate, "LGE measured no count, and 0 is a claim", file: file, line: line)
        XCTAssertNil(model.errorLineLimit, "the refusal shows in full", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            panelContentHeight + 1, panelFittingHeight,
            "the sheet panel grows with its content, so a long refusal is not cut (Q-W3)", file: file, line: line
        )
    }

    func testAMissingBAMShowsItsWordsInFullAndTurnsOffExtract() async throws {
        let model = try await presentAndWaitForTheEstimate(resultPath: makeResult(linkedOut: false), host: makeHost())
        try assertRefusalShown(model, .bamNotFound(sampleId: "S1"))
    }

    func testABAMLinkedOutOfTheResultShowsItsWordsInFullAndTurnsOffExtract() async throws {
        let model = try await presentAndWaitForTheEstimate(resultPath: makeResult(linkedOut: true), host: makeHost())
        try assertRefusalShown(model, .bamOutsideResult(sampleId: "S1"))
    }

    /// U-W3, Q-W3. A long sample name makes a long refusal, which the sheet shows in full, and the panel grows to hold
    /// it. The `S1` refusal is presented first in the same test, so the larger fitting height of the long one shows
    /// that the message needed room.
    func testALongSampleNameShowsItsRefusalInFullAndTheSheetGrows() async throws {
        let short = try await presentAndWaitForTheEstimate(resultPath: makeResult(linkedOut: true), host: makeHost())
        try assertRefusalShown(short, .bamOutsideResult(sampleId: "S1"))
        let shortFittingHeight = panelFittingHeight

        let id = String(repeating: "S", count: 200)
        let long = try await presentAndWaitForTheEstimate(
            resultPath: makeResult(linkedOut: true, sampleId: id), host: makeHost(), sampleId: id
        )
        try assertRefusalShown(long, .bamOutsideResult(sampleId: id))
        XCTAssertGreaterThan(
            panelFittingHeight, shortFittingHeight,
            "the long refusal needs more room than the S1 refusal"
        )
    }

    /// Negative control. Every other failed estimate keeps the prefix and Extract, shows no count and keeps the
    /// three-line limit, since the run may still succeed and samtools stderr can be long.
    func testAnotherFailedEstimateKeepsThePrefixAndExtract() throws {
        let model = ClassifierExtractionDialogViewModel(tool: .esviritu, selectionCount: 1, suggestedName: "reads")
        let error = ClassifierExtractionError.kraken2OutputMissing(URL(fileURLWithPath: "/work/classification.kraken"))
        model.applyEstimateFailure(error)
        XCTAssertEqual(model.errorMessage, "Could not estimate read count: " + (try words(error)))
        XCTAssertTrue(model.isPrimaryEnabled)
        XCTAssertFalse(model.showsReadEstimate)
        XCTAssertEqual(model.errorLineLimit, 3)
    }

    /// Phase 3.1 lane NAO-BAM-STALE (UX ruling UX-NAO-BAM-STALE 4a, test T7). A NAO-MGS BAM made before the strand fix is
    /// refused by the resolver, so the sheet shows the refusal's words in full, with no prefix, no count, Extract off
    /// and no line limit, like the other BAM refusals. The words are spelled out here, so a change of wording fails.
    func testStaleNaoMgsRefusalShowsItsWordsAndTurnsOffExtract() {
        let model = ClassifierExtractionDialogViewModel(tool: .naomgs, selectionCount: 1, suggestedName: "reads")
        model.applyEstimateFailure(ClassifierExtractionError.naoMgsBAMBeforeStrandFix(sampleId: "S1"))
        XCTAssertEqual(
            model.errorMessage,
            "The alignment file of sample 'S1' comes from an earlier NAO-MGS import, which stored reads that map to the "
                + "reverse strand the wrong way round, so Lungfish does not extract reads from it. Import the same NAO-MGS "
                + "results file again in the Import Center (NAO-MGS Results), then extract from the new result. "
                + "The counts and read IDs shown for this result are right."
        )
        XCTAssertFalse(model.isPrimaryEnabled, "the run would only show the same refusal")
        XCTAssertFalse(model.showsReadEstimate, "LGE measured no count, and 0 is a claim")
        XCTAssertNil(model.errorLineLimit, "the refusal shows in full")
    }

    /// The test that a refusal blocks the run is true for exactly the three BAM refusals.
    func testOnlyTheThreeBAMRefusalsBlockTheExtraction() {
        let url = URL(fileURLWithPath: "/work/x")
        let others: [ClassifierExtractionError] = [
            .unsupportedBAMTool(.kraken2), .kraken2OutputMissing(url), .kraken2TreeMissing(url), .kraken2SourceMissing,
            .samtoolsFailed(sampleId: "S1", stderr: "e"), .clipboardCapExceeded(requested: 2, cap: 1),
            .destinationNotWritable(url), .fastaConversionFailed("r"), .mixedSampleSelectionModes, .zeroReadsExtracted,
            .allSamplesSkipped(["S1"]), .cancelled, .unsupportedCopyDestination,
        ]
        XCTAssertTrue(ClassifierExtractionError.bamNotFound(sampleId: "S1").blocksExtraction)
        XCTAssertTrue(ClassifierExtractionError.bamOutsideResult(sampleId: "S1").blocksExtraction)
        XCTAssertTrue(ClassifierExtractionError.naoMgsBAMBeforeStrandFix(sampleId: "S1").blocksExtraction)
        XCTAssertTrue(others.filter(\.blocksExtraction).isEmpty)
    }
}
