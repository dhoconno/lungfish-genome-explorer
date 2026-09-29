// SidebarIncompleteAnalysisTests.swift - Analysis results stay out of the sidebar until their run completes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit

@MainActor
final class SidebarIncompleteAnalysisTests: XCTestCase {
    private var tempRoot: URL!
    private var projectURL: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarIncompleteAnalysis-\(UUID().uuidString)", isDirectory: true)
        projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
    }

    private func analysisTitles() -> [String] {
        let nodes = SidebarProjectScanner.scanRootNodes(from: projectURL)
        guard let group = nodes.first(where: { $0.title == "Analyses" }) else { return [] }
        return group.children.compactMap { $0.url?.lastPathComponent }
    }

    func testRunningAnalysisIsHiddenAndAppearsWhenItsOperationCompletes() throws {
        let center = OperationCenter()
        let batch = try AnalysesFolder.createAnalysisDirectory(tool: "taxtriage", in: projectURL, isBatch: true)
        let sample = try AnalysesFolder.batchSampleDirectory(named: "S1", in: batch)
        try "report".write(to: sample.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let id = center.start(title: "TaxTriage (1 sample)", detail: "Running")
        center.trackAnalysisOutput(batch, for: id)

        XCTAssertEqual(analysisTitles(), [], "a running analysis is not in the sidebar")

        center.complete(id: id, detail: "Done")
        XCTAssertEqual(analysisTitles(), [batch.lastPathComponent])
    }

    func testCompletedWithWarningsAnalysisAppears() throws {
        let center = OperationCenter()
        let dir = try AnalysesFolder.createAnalysisDirectory(tool: "viralrecon", in: projectURL)
        let id = center.start(title: "Viral Recon", detail: "Running")
        center.trackAnalysisOutput(dir, for: id)
        center.completeWithWarning(id: id, detail: "1 sample skipped")
        XCTAssertEqual(analysisTitles(), [dir.lastPathComponent])
    }

    func testInterruptedRunWithDeadProducerStaysHidden() throws {
        let analyses = try AnalysesFolder.url(for: projectURL)
        let dir = analyses.appendingPathComponent("kraken2-2026-09-28T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "kraken2", isBatch: false), to: dir)
        try AnalysisRunRecord.begin(
            AnalysisRunRecord(analysisName: "Kraken2", processIdentifier: 999_999, processStartTime: 1),
            in: dir
        )
        XCTAssertEqual(AnalysisRunRecord.load(from: dir)?.liveness(), .interrupted)
        XCTAssertEqual(analysisTitles(), [], "an interrupted run is never shown in the sidebar")
    }

    func testLegacyAnalysisWithoutRecordIsShown() throws {
        let analyses = try AnalysesFolder.url(for: projectURL)
        let dir = analyses.appendingPathComponent("kraken2-2026-01-01T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: "kraken2", isBatch: false), to: dir)
        XCTAssertEqual(analysisTitles(), [dir.lastPathComponent])
    }

    func testIncompleteResultBundleOutsideAnalysesIsHidden() throws {
        let bundle = projectURL.appendingPathComponent("Alignment.lungfishmsa", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(AnalysisRunRecord(analysisName: "MAFFT"), in: bundle)
        XCTAssertFalse(
            SidebarProjectScanner.shouldIncludeEntry(bundle, isDirectory: true, context: .projectRoot)
        )
        AnalysisRunRecord.markComplete(bundle)
        XCTAssertTrue(
            SidebarProjectScanner.shouldIncludeEntry(bundle, isDirectory: true, context: .projectRoot)
        )
    }

    // MARK: - Interrupted-run discovery

    func testInterruptedRunDiscoveryListsDeadProducersOnly() async throws {
        let center = OperationCenter()
        let analyses = try AnalysesFolder.url(for: projectURL)

        let dead = analyses.appendingPathComponent("kraken2-2026-09-28T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        try "x".write(to: dead.appendingPathComponent("partial.txt"), atomically: true, encoding: .utf8)
        try AnalysisRunRecord.begin(
            AnalysisRunRecord(analysisName: "Kraken2", processIdentifier: 999_999, processStartTime: 1),
            in: dead
        )

        let foreign = analyses.appendingPathComponent("esviritu-2026-09-28T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(
            AnalysisRunRecord(analysisName: "EsViritu", hostName: "some-other-mac", processIdentifier: 999_999),
            in: foreign
        )

        let live = try AnalysesFolder.createAnalysisDirectory(tool: "taxtriage", in: projectURL, isBatch: true)
        let liveID = center.start(title: "TaxTriage", detail: "Running")
        center.trackAnalysisOutput(live, for: liveID)

        // Owned by this process but no longer tracked by any operation: the
        // run that created it ended without finishing it.
        let orphan = try AnalysesFolder.createAnalysisDirectory(tool: "minimap2", in: projectURL)

        let registered = await InterruptedAnalysisRunDiscovery.registerInterruptedRuns(
            in: projectURL,
            center: center
        )
        let listed = Set(registered.compactMap { id in
            center.items.first(where: { item in item.id == id })?.interruptedRunDirectory?.lastPathComponent
        })
        XCTAssertEqual(listed, Set([dead.lastPathComponent, orphan.lastPathComponent]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dead.path), "discovery never deletes")
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(foreign))
    }

    func testRemovingPartialOutputDeletesTheDirectoryAndTheRow() async throws {
        let center = OperationCenter()
        let analyses = try AnalysesFolder.url(for: projectURL)
        let dead = analyses.appendingPathComponent("kraken2-2026-09-28T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        try AnalysisRunRecord.begin(
            AnalysisRunRecord(analysisName: "Kraken2", processIdentifier: 999_999, processStartTime: 1),
            in: dead
        )
        let ids = await InterruptedAnalysisRunDiscovery.registerInterruptedRuns(in: projectURL, center: center)
        let id = try XCTUnwrap(ids.first)

        try InterruptedAnalysisRunDiscovery.removePartialOutput(itemID: id, center: center)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertNil(center.items.first { $0.id == id })
    }
}
