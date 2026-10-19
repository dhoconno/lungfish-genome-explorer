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

    override func setUp() async throws {
        try await super.setUp()
        captureOnly = TaxonomyReadExtractionAction.shared.testingCaptureOnly
        TaxonomyReadExtractionAction.shared.testingCaptureOnly = false
    }

    override func tearDown() async throws {
        TaxonomyReadExtractionAction.shared.testingCaptureOnly = captureOnly
        for folder in folders { TestTempDirectory.cleanup(folder) }
        folders = []
        try await super.tearDown()
    }

    /// An EsViritu result of sample `S1`. With `linkedOut` its recorded BAM is a link to a file outside the result.
    private func makeResult(linkedOut: Bool) throws -> URL {
        let recorded = "S1/bams/S1.third.filt.sorted.bam"
        let root = try TestTempDirectory.make(prefix: "refused-estimate")
        folders.append(root)
        let resultPath = root.appendingPathComponent("esviritu.sqlite")
        try EsVirituDatabase.create(
            at: resultPath,
            rows: [EsVirituDetectionRow(
                sample: "S1", virusName: "Test virus", description: nil, contigLength: 1_000, segment: nil,
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
        let outsideBAM = outside.appendingPathComponent("S1.third.filt.sorted.bam")
        try Data([0x1F, 0x8B]).write(to: outsideBAM)
        let link = root.appendingPathComponent(recorded)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideBAM)
        return resultPath
    }

    /// Presents the sheet over `resultPath` and returns its model once the estimate has ended in a message.
    private func presentAndWaitForTheEstimate(
        resultPath: URL, host: NSWindow
    ) async throws -> ClassifierExtractionDialogViewModel {
        let context = TaxonomyReadExtractionAction.Context(
            tool: .esviritu,
            resultPath: resultPath,
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["NC_000001.1"], taxIds: [])],
            suggestedName: "reads"
        )
        TaxonomyReadExtractionAction.shared.present(context: context, hostWindow: host)
        let sheet = try XCTUnwrap(host.attachedSheet, "the extraction sheet is attached to its host window")
        let controller = try XCTUnwrap(sheet.contentViewController as? NSHostingController<ClassifierExtractionDialog>)
        let model = controller.rootView.model
        for _ in 0..<300 where model.errorMessage == nil {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
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

    /// Whether the sheet's Extract button is on, read from the model state that feeds it: not running, and a name
    /// where the destination takes one.
    private func extractIsEnabled(_ model: ClassifierExtractionDialogViewModel) -> Bool {
        !(model.isRunning || (model.destination.showsNameField
            && model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    // MARK: - The sheet after a refusal, as it is at the base (M1 pin)

    func testAMissingBAMShowsThePrefixedWordsWithAZeroCountAndExtractOn() async throws {
        let model = try await presentAndWaitForTheEstimate(resultPath: makeResult(linkedOut: false), host: makeHost())
        XCTAssertEqual(model.errorMessage, "Could not estimate read count: " + (try words(.bamNotFound(sampleId: "S1"))))
        XCTAssertEqual(model.estimatedReadCount, 0)
        XCTAssertTrue(extractIsEnabled(model))
    }

    func testABAMLinkedOutOfTheResultShowsThePrefixedWordsWithAZeroCountAndExtractOn() async throws {
        let model = try await presentAndWaitForTheEstimate(resultPath: makeResult(linkedOut: true), host: makeHost())
        XCTAssertEqual(model.errorMessage, "Could not estimate read count: " + (try words(.bamOutsideResult(sampleId: "S1"))))
        XCTAssertEqual(model.estimatedReadCount, 0)
        XCTAssertTrue(extractIsEnabled(model))
    }
}
