// InspectorBatchDetailsStaleTests.swift - A single-result route clears the Inspector's batch block (Phase 2.14 lane OBS14)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Walk obs-14 (row 100). Both NAO-MGS results of the walk showed a Kraken2 Operation Details block (Tool, Run,
// Confidence, Database) and Source Samples from the project's earlier Kraken2 run. The batch route clears the
// block after it shows TaxTriage, NAO-MGS or NVD, but the sidebar's content route calls the NAO-MGS and NVD
// single-result routes directly, and neither cleared it.
//
// Each test runs the routes the sidebar runs. It selects a Kraken2 batch folder (`.batchGroup`, which sets the
// block through `displayBatchGroup`), then selects the NAO-MGS or NVD result (`displayContent(for:)`), and reads the
// Inspector's Summary view model. No test here reads source text. The result bundles come from the committed
// virus hits and BLAST tables through the production parser and database writers (RoutingSafetyNetFixtures).
// Opening a result writes nothing (UX 6), so each test also hashes the result folder before and after the open.
//
// The last test pins the one set of the block that can run after an await. A Kraken2 database build that ends
// after another result opens re-displays its batch through `commitDatabaseBuildCompletion`, which commits only
// while the request that began the build is still the current one.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class InspectorBatchDetailsStaleTests: XCTestCase {
    private var root: URL!
    private var controller: MainSplitViewController!
    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "inspector-batch-details-stale")
        let split = MainSplitViewController()
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        host.contentViewController = split
        host.layoutIfNeeded()
        split.view.layoutSubtreeIfNeeded()
        controller = split
        window = host
    }

    override func tearDown() async throws {
        window.contentViewController = nil
        window = nil
        controller = nil
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The red tests

    /// A NAO-MGS result opened from the sidebar after a Kraken2 batch shows no Operation Details and no Source
    /// Samples, and opening it writes nothing into the result.
    func testNaoMgsAfterKraken2ShowsNoOperationDetails() async throws {
        let kraken2 = try makeKraken2Batch()
        let naoMgs = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-stale-check", in: root).bundle
        showKraken2Batch(kraken2)
        let before = try TreeDigest.of(naoMgs)

        controller.displayContent(for: SidebarItem(title: naoMgs.lastPathComponent, type: .naoMgsResult, url: naoMgs))

        assertNoBatchBlock("a NAO-MGS result as it opens")
        let loaded = await waitUntil(budget: .lookup) { self.summary.naoMgsManifest != nil }
        XCTAssertTrue(loaded, "the NAO-MGS result never finished loading")
        assertNoBatchBlock("a loaded NAO-MGS result")
        XCTAssertEqual(try TreeDigest.of(naoMgs), before, "opening a NAO-MGS result writes nothing into it")
    }

    /// The NVD twin of the test above.
    func testNvdAfterKraken2ShowsNoOperationDetails() async throws {
        let kraken2 = try makeKraken2Batch()
        let nvd = try await RoutingSafetyNetFixtures.nvdResult(named: "nvd-stale-check", in: root).bundle
        showKraken2Batch(kraken2)
        let before = try TreeDigest.of(nvd)

        controller.displayContent(for: SidebarItem(title: nvd.lastPathComponent, type: .nvdResult, url: nvd))

        assertNoBatchBlock("an NVD result as it opens")
        let loaded = await waitUntil(budget: .lookup) { self.summary.nvdManifest != nil }
        XCTAssertTrue(loaded, "the NVD result never finished loading")
        assertNoBatchBlock("a loaded NVD result")
        XCTAssertEqual(try TreeDigest.of(nvd), before, "opening an NVD result writes nothing into it")
    }

    // MARK: - The pin

    /// The Kraken2 database build placeholder begins a display request, and the build's end re-displays the batch
    /// only while that request is current (`triggerDatabaseBuild`). A NAO-MGS result that opens in between begins
    /// its own request, so the late display commits nothing and sets no block (S-F6 of the 2.14 votes).
    func testKraken2BatchDetailsLandingAfterNaoMgsOpensSetNoBlock() async throws {
        let kraken2 = try makeKraken2Batch()
        let naoMgs = try await RoutingSafetyNetFixtures.naoMgsResult(named: "naomgs-late-set", in: root).bundle
        let buildRequest = controller.beginDatabaseBuildRequest(tool: "kraken2", resultURL: kraken2)

        controller.displayContent(for: SidebarItem(title: naoMgs.lastPathComponent, type: .naoMgsResult, url: naoMgs))
        let loaded = await waitUntil(budget: .lookup) { self.summary.naoMgsManifest != nil }
        XCTAssertTrue(loaded, "the NAO-MGS result never finished loading")
        controller.commitDatabaseBuildCompletion(buildRequest) {
            controller.displayBatchGroup(at: kraken2)
        }

        assertNoBatchBlock("a NAO-MGS result after a Kraken2 database build ended late")
        XCTAssertNil(controller.viewerController.taxonomyViewController, "the late display must not take the viewport")
    }

    // MARK: - Helpers

    private var summary: DocumentSectionViewModel {
        controller.inspectorController.viewModel.documentSectionViewModel
    }

    private func assertNoBatchBlock(_ shown: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(summary.batchOperationTool, "\(shown) must show no Operation Details", file: file, line: line)
        XCTAssertEqual(summary.batchOperationParameters, [:], "\(shown) must show no parameters", file: file, line: line)
        XCTAssertNil(summary.batchOperationTimestamp, "\(shown) must show no run date", file: file, line: line)
        XCTAssertTrue(summary.batchSourceSampleURLs.isEmpty, "\(shown) must show no Source Samples", file: file, line: line)
    }

    /// Selects the Kraken2 batch as the sidebar does and checks that the block the walk saw is set.
    private func showKraken2Batch(_ batch: URL, file: StaticString = #filePath, line: UInt = #line) {
        controller.displayContent(for: SidebarItem(title: batch.lastPathComponent, type: .batchGroup, url: batch))
        XCTAssertEqual(summary.batchOperationTool, "Kraken2", "the Kraken2 batch sets the block", file: file, line: line)
        XCTAssertEqual(summary.batchOperationParameters["Database"], "Viral 2026-01", file: file, line: line)
        XCTAssertEqual(summary.batchSourceSampleURLs.map(\.sampleId), ["Sample A"], file: file, line: line)
        XCTAssertNotNil(controller.viewerController.taxonomyViewController, "the batch is shown", file: file, line: line)
    }

    /// A Kraken2 result folder whose sidecar names its configuration, so that `displayBatchGroup` sets the block.
    private func makeKraken2Batch() throws -> URL {
        let batch = root.appendingPathComponent("Kraken2 Results", isDirectory: true)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        _ = try Kraken2Database.create(
            at: batch.appendingPathComponent("kraken2.sqlite"),
            rows: [
                Kraken2ClassificationRow(
                    sample: "sample-a", taxonName: "Escherichia coli", taxId: 562, rank: "S", rankDisplayName: "Species",
                    readsDirect: 50, readsClade: 100, percentage: 1.0, parentTaxId: nil, depth: 0, fractionDirect: 0.0
                ),
            ],
            metadata: ["tool": "kraken2"]
        )
        try AnalysesFolder.writeAnalysisMetadata(
            AnalysesFolder.AnalysisMetadata(tool: "kraken2", isBatch: true, created: Date()),
            to: batch
        )
        let sidecar = """
        {"config":{"databaseName":"Viral","databaseVersion":"2026-01","goal":"profile","confidence":0.2,\
        "minimumHitGroups":2,"threads":1,"sampleDisplayName":"Sample A"},\
        "toolVersion":"2.1.3","runtime":42,"savedAt":"2026-10-01T00:00:00Z"}
        """
        try sidecar.write(
            to: batch.appendingPathComponent(ClassificationResult.sidecarFilename),
            atomically: true,
            encoding: .utf8
        )
        return batch
    }
}
