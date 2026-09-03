// EsVirituBatchInspectorStateTests.swift - Inspector state after opening an EsViritu batch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reported 2026-09-03: selecting an EsViritu batch in the sidebar left the
// Inspector sidecar almost empty. The sample filter, the batch details and the
// panel layout controls were all missing. This drives the same path the sidebar
// selection takes and asserts the Inspector ends up in metagenomics mode with
// the classifier sample state installed.

import XCTest
import AppKit
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

@MainActor
final class EsVirituBatchInspectorStateTests: XCTestCase {

    private func makeController() -> (MainSplitViewController, NSWindow) {
        let controller = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// Builds a minimal EsViritu batch directory: the SQLite database the
    /// viewer reads plus the analysis metadata the router consults.
    private func makeBatch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EsVirituBatchInspectorStateTests-\(UUID().uuidString)", isDirectory: true)
        let batch = root.appendingPathComponent("esviritu-batch-2026-09-03T00-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)

        try EsVirituDatabase.create(
            at: batch.appendingPathComponent("esviritu.sqlite"),
            rows: [
                EsVirituDetectionRow(
                    sample: "sample-a", virusName: "Example virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000001.1",
                    assembly: "ASM_1", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 4, uniqueReads: 3,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 4, bamPath: nil, bamIndexPath: nil
                ),
                EsVirituDetectionRow(
                    sample: "sample-b", virusName: "Other virus", description: nil,
                    contigLength: 1_000, segment: nil, accession: "NC_000002.1",
                    assembly: "ASM_2", assemblyLength: 1_000, kingdom: nil, phylum: nil,
                    tclass: nil, torder: nil, family: nil, genus: nil, species: nil,
                    subspecies: nil, rpkmf: 1, readCount: 2, uniqueReads: 2,
                    coveredBases: 1_000, meanCoverage: 1, avgReadIdentity: 0.99,
                    pi: nil, filteredReadsInSample: 2, bamPath: nil, bamIndexPath: nil
                ),
            ],
            metadata: ["tool": "esviritu"]
        )
        let metadata = """
        {"created":"2026-09-03T00:00:00Z","isBatch":true,"tool":"esviritu"}
        """
        try metadata.write(
            to: batch.appendingPathComponent("analysis-metadata.json"),
            atomically: true,
            encoding: .utf8
        )
        return batch
    }

    private func assertInspectorShowsBatch(
        _ controller: MainSplitViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let inspector = controller.inspectorController!
        let document = inspector.viewModel.documentSectionViewModel
        XCTAssertEqual(inspector.viewModel.contentMode, .metagenomics,
                       "Inspector must mirror the metagenomics viewport mode", file: file, line: line)
        XCTAssertTrue(inspector.viewModel.availableTabs.contains(.resultSummary),
                      "Summary tab must be offered for a classifier batch", file: file, line: line)
        XCTAssertTrue(inspector.viewModel.availableTabs.contains(inspector.viewModel.selectedTab),
                      "Selected tab \(inspector.viewModel.selectedTab) is not available: \(inspector.viewModel.availableTabs)",
                      file: file, line: line)
        XCTAssertNotNil(document.classifierPickerState, "Sample picker state must be installed", file: file, line: line)
        XCTAssertEqual(document.classifierSampleEntries.map(\.id).sorted(), ["sample-a", "sample-b"],
                       file: file, line: line)
    }

    func testDisplayBatchGroupPopulatesInspector() throws {
        let batch = try makeBatch()
        defer { try? FileManager.default.removeItem(at: batch.deletingLastPathComponent()) }
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)

        assertInspectorShowsBatch(controller)
    }

    func testSidebarBatchGroupSelectionPopulatesInspector() throws {
        let batch = try makeBatch()
        defer { try? FileManager.default.removeItem(at: batch.deletingLastPathComponent()) }
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        let item = SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch)
        controller.displayContent(for: item)

        assertInspectorShowsBatch(controller)
    }

    /// The evidence viewer clears itself whenever the detail pane shows the
    /// overview, which happens on every reselection. None of those clears may
    /// take the Inspector out of metagenomics mode while the batch is shown.
    func testClearingEvidenceAfterLoadKeepsInspectorOnSummary() throws {
        let batch = try makeBatch()
        defer { try? FileManager.default.removeItem(at: batch.deletingLastPathComponent()) }
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        controller.displayBatchGroup(at: batch)
        let esViritu = try XCTUnwrap(controller.viewerController.esVirituViewController)
        esViritu.clearClassifierAlignmentEvidence()

        assertInspectorShowsBatch(controller)
        XCTAssertEqual(controller.inspectorController.viewModel.selectedTab, .resultSummary)
    }
}
