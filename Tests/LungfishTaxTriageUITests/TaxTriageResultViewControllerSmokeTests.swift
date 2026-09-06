// TaxTriageResultViewControllerSmokeTests.swift - Standalone smoke test for the TaxTriage leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishKit

@MainActor
private final class TaxTriageRecordingEvidenceViewer: NSObject, ClassifierAlignmentViewerProviding {
    let viewController = NSViewController()
    private(set) var status: ClassifierAlignmentViewerStatus = .idle
    var onStatusChanged: (@MainActor @Sendable (ClassifierAlignmentViewerStatus) -> Void)?
    private(set) var requests: [ClassifierAlignmentEvidenceRequest] = []
    private(set) var clearCount = 0
    override init() { super.init(); viewController.view = NSView() }
    func display(_ request: ClassifierAlignmentEvidenceRequest) { requests.append(request) }
    func clear() { clearCount += 1 }
    func discardRecordedRequests() { requests.removeAll() }
}

final class TaxTriageResultViewControllerSmokeTests: XCTestCase {
    @MainActor func testImportedMetadataUpdatesActualOrganismAndBatchFlatTableChoosersAndCells() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageMetadata-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = [
            Self.taxonomyRow(sample: "sample-1", organism: "Alpha virus", taxId: 1, tassScore: 0.9, reads: 20),
            Self.taxonomyRow(sample: "sample-2", organism: "Beta virus", taxId: 2, tassScore: 0.8, reads: 10),
        ]
        let (vc, _) = try makeConfiguredBatchController(tempDir: tempDir, rows: rows)
        vc.testOrganismTableView.rows = [
            TaxTriageTableRow(organism: "Alpha virus", tassScore: 0.9, reads: 20, uniqueReads: 10, taxId: 1),
        ]
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nsample-1\tcase\nsample-2\tcontrol\n".utf8),
            knownSampleIds: ["sample-1", "sample-2"]
        )

        vc.applySampleMetadata(store)
        let organismTable = vc.testOrganismTableView.testingTableView
        let batchTable = vc.testBatchFlatTableView.testTableView
        XCTAssertTrue(Set(["Cohort"]).isSubset(of: Self.metadataMenuTitles(in: organismTable)))
        XCTAssertTrue(Set(["Cohort"]).isSubset(of: Self.metadataMenuTitles(in: batchTable)))

        try Self.showMetadataColumn(named: "Cohort", in: organismTable)
        try Self.showMetadataColumn(named: "Cohort", in: batchTable)
        vc.testOrganismTableView.metadataColumns.update(store: store, sampleId: "sample-1")

        XCTAssertEqual(vc.testOrganismTableView.testingCell(column: "metadata_Cohort", row: 0)?.stringValue, "case")
        let sample1Row = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex { $0.sample == "sample-1" })
        let sample2Row = try XCTUnwrap(vc.testBatchFlatTableView.displayedRows.firstIndex { $0.sample == "sample-2" })
        XCTAssertEqual(vc.testBatchFlatTableView.testCellText(row: sample1Row, columnID: "metadata_Cohort").primary, "case")
        XCTAssertEqual(vc.testBatchFlatTableView.testCellText(row: sample2Row, columnID: "metadata_Cohort").primary, "control")
    }
    func testTaxTriageLeafDoesNotDependOnMiniBAM() throws {
        let source = try String(contentsOfFile: "Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift", encoding: .utf8)
        XCTAssertFalse(source.contains("MiniBAMViewController"))
        XCTAssertFalse(source.contains("createSymbolicLink"))
        XCTAssertTrue(source.contains("let name = \"\\(sampleID).dwnld.references.fasta\""))
    }

    @MainActor func testViewControllerInstantiates() {
        let vc = TaxTriageResultViewController()
        XCTAssertNotNil(vc.view)
    }

    @MainActor func testDatabaseLoadDefaultsToStackedLayoutAndSelectsTopRow() throws {
        let suiteName = "TaxTriageLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageStackedDefault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let rows = [
            TaxTriageTaxonomyRow(
                sample: "sample-1",
                organism: "Aeromonas salmonicida",
                taxId: 645,
                status: nil,
                tassScore: 0.99,
                readsAligned: 21_383,
                uniqueReads: 9_690,
                pctReads: nil,
                pctAlignedReads: nil,
                coverageBreadth: nil,
                meanCoverage: nil,
                meanDepth: nil,
                confidence: nil,
                k2Reads: nil,
                parentK2Reads: nil,
                giniCoefficient: nil,
                meanBaseQ: nil,
                meanMapQ: nil,
                mapqScore: nil,
                disparityScore: nil,
                minhashScore: nil,
                diamondIdentity: nil,
                k2DisparityScore: nil,
                siblingsScore: nil,
                breadthWeightScore: nil,
                hhsPercentile: nil,
                isAnnotated: nil,
                annClass: nil,
                microbialCategory: nil,
                highConsequence: nil,
                isSpecies: nil,
                pathogenicSubstrains: nil,
                sampleType: nil,
                bamPath: nil,
                bamIndexPath: nil,
                primaryAccession: "NZ_CP110645.1",
                accessionLength: 4_866_465
            )
        ]
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = defaults
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while vc.testBatchFlatTableView.displayedRows.count < rows.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, rows.count)
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testRightPaneContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testLeftPaneContainer)
        XCTAssertEqual(vc.testBatchFlatTableView.selectedMetrics().map(\.organism), ["Aeromonas salmonicida"])
        XCTAssertLessThanOrEqual(
            vc.testLeftPaneContainer.frame.height,
            1,
            "Auto-selecting a TaxTriage database row without BAM data must keep the empty miniBAM pane collapsed"
        )
    }

    @MainActor func testDatabaseRowWithBamDataRevealsMiniBAMPane() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageMiniBAMVisible-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bamURL = tempDir.appendingPathComponent("sample-1.bam")
        try Data().write(to: bamURL)
        let indexURL = tempDir.appendingPathComponent("stored-index.csi")
        try Data().write(to: indexURL)
        let referenceURL = tempDir.appendingPathComponent("download/sample-1.dwnld.references.fasta")
        try FileManager.default.createDirectory(at: referenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(">NC_123456.1\nACGT\n".utf8).write(to: referenceURL)
        let secondBAMURL = tempDir.appendingPathComponent("sample-2.bam")
        let secondIndexURL = tempDir.appendingPathComponent("stored-index-2.bai")
        let secondReferenceURL = tempDir.appendingPathComponent("download/sample-2.dwnld.references.fasta")
        try Data().write(to: secondBAMURL)
        try Data().write(to: secondIndexURL)
        try Data(">NC_654321.1\nTGCA\n".utf8).write(to: secondReferenceURL)

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let row = TaxTriageTaxonomyRow(
            sample: "sample-1",
            organism: "Influenza A virus",
            taxId: 11320,
            status: nil,
            tassScore: 0.95,
            readsAligned: 37,
            uniqueReads: 21,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: 82.5,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: "high",
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: bamURL.path,
            bamIndexPath: indexURL.path,
            primaryAccession: "NC_123456.1",
            accessionLength: 1_000
        )
        let secondRow = TaxTriageTaxonomyRow(
            sample: "sample-2",
            organism: "Influenza B virus",
            taxId: 11520,
            status: nil,
            tassScore: 0.91,
            readsAligned: 31,
            uniqueReads: 18,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: 72.5,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: "high",
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: secondBAMURL.path,
            bamIndexPath: secondIndexURL.path,
            primaryAccession: "NC_654321.1",
            accessionLength: 2_000
        )
        let db = try TaxTriageDatabase.create(
            at: dbURL,
            rows: [row, secondRow],
            metadata: ["tool": "taxtriage"]
        )

        let recorder = TaxTriageRecordingEvidenceViewer()
        var factoryInvocationCount = 0
        let vc = TaxTriageResultViewController()
        vc.classifierAlignmentViewerFactory = {
            factoryInvocationCount += 1
            return recorder
        }
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while vc.testBatchFlatTableView.displayedRows.count < 2 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, 2)

        let firstIndex = try XCTUnwrap(
            vc.testBatchFlatTableView.displayedRows.firstIndex { $0.sample == "sample-1" }
        )
        let secondIndex = try XCTUnwrap(
            vc.testBatchFlatTableView.displayedRows.firstIndex { $0.sample == "sample-2" }
        )
        let table = vc.testBatchFlatTableView.testTableView
        table.deselectAll(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        recorder.discardRecordedRequests()
        table.selectRowIndexes(IndexSet(integer: firstIndex), byExtendingSelection: false)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(
            vc.testLeftPaneContainer.isHidden,
            "Selecting a TaxTriage database row with BAM data and accession mapping should reveal the miniBAM pane"
        )
        XCTAssertGreaterThan(vc.testLeftPaneContainer.frame.height, 100)
        table.selectRowIndexes(IndexSet(integer: secondIndex), byExtendingSelection: false)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(factoryInvocationCount, 1)
        XCTAssertEqual(recorder.requests.count, 2)
        let firstRequest = recorder.requests[0]
        XCTAssertEqual(firstRequest.workflow, .taxTriage)
        XCTAssertEqual(firstRequest.bamURL, bamURL)
        XCTAssertEqual(firstRequest.index.url, indexURL)
        XCTAssertEqual(firstRequest.index.kind, .csi)
        XCTAssertEqual(firstRequest.sample.canonicalID, "sample-1")
        XCTAssertEqual(firstRequest.contig.name, "NC_123456.1")
        XCTAssertEqual(firstRequest.contig.expectedLength, 1_000)
        XCTAssertEqual(firstRequest.referenceCandidate?.fastaURL, referenceURL)
        let secondRequest = recorder.requests[1]
        XCTAssertEqual(secondRequest.bamURL, secondBAMURL)
        XCTAssertEqual(secondRequest.index.url, secondIndexURL)
        XCTAssertEqual(secondRequest.index.kind, .bai)
        XCTAssertEqual(secondRequest.sample.canonicalID, "sample-2")
        XCTAssertEqual(secondRequest.contig.name, "NC_654321.1")
        XCTAssertEqual(secondRequest.contig.expectedLength, 2_000)
        XCTAssertEqual(secondRequest.referenceCandidate?.fastaURL, secondReferenceURL)

        let clearCountBeforeMultiSelection = recorder.clearCount
        table.selectRowIndexes(
            IndexSet([firstIndex, secondIndex]),
            byExtendingSelection: false
        )
        XCTAssertEqual(recorder.clearCount, clearCountBeforeMultiSelection + 1)
        table.deselectAll(nil)
        XCTAssertEqual(recorder.clearCount, clearCountBeforeMultiSelection + 2)
    }

    @MainActor func testDatabaseConfiguredBeforeWindowDisplaysBatchTableAfterAttach() throws {
        let suiteName = "TaxTriageLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(MetagenomicsPanelLayout.listLeading.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        defaults.set(true, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageInitialLayout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let row = TaxTriageTaxonomyRow(
            sample: "sample-1",
            organism: "Influenza A virus",
            taxId: 11320,
            status: nil,
            tassScore: 0.95,
            readsAligned: 12,
            uniqueReads: 12,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: nil,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: nil,
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: nil,
            bamIndexPath: nil,
            primaryAccession: "NC_123456.1",
            accessionLength: 1000
        )
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = defaults
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(vc.testBatchFlatTableView.isHidden)
        XCTAssertGreaterThan(vc.testRightPaneContainer.frame.width, 300)
        XCTAssertGreaterThan(vc.testBatchFlatTableView.frame.width, 300)
        XCTAssertGreaterThan(vc.testBatchFlatTableView.frame.height, 300)
    }

    @MainActor func testDatabaseLayoutSwitchToDetailLeadingKeepsBatchTableVisible() throws {
        let suiteName = "TaxTriageLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(MetagenomicsPanelLayout.stacked.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        defaults.set(false, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageDetailLeadingSwitch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let row = TaxTriageTaxonomyRow(
            sample: "sample-1",
            organism: "Influenza A virus",
            taxId: 11320,
            status: nil,
            tassScore: 0.95,
            readsAligned: 12,
            uniqueReads: 12,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: nil,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: nil,
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: nil,
            bamIndexPath: nil,
            primaryAccession: "NC_123456.1",
            accessionLength: 1000
        )
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        vc.layoutDefaults = defaults
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while vc.testBatchFlatTableView.displayedRows.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, 1)
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        defaults.set(MetagenomicsPanelLayout.detailLeading.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        defaults.set(false, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
        NotificationCenter.default.post(name: .metagenomicsLayoutSwapRequested, object: nil)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testLeftPaneContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testRightPaneContainer)
        XCTAssertLessThanOrEqual(vc.testLeftPaneContainer.frame.width, 1)
        XCTAssertGreaterThan(vc.testRightPaneContainer.frame.width, 300)
        XCTAssertGreaterThan(vc.testBatchFlatTableView.frame.width, 300)
    }

    @MainActor func testActionBarBlastVerifyForwardsSelectedDatabaseRow() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageActionBarBlast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let row = TaxTriageTaxonomyRow(
            sample: "sample-1",
            organism: "Influenza A virus",
            taxId: 11320,
            status: nil,
            tassScore: 0.95,
            readsAligned: 37,
            uniqueReads: 21,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: 82.5,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: "high",
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: nil,
            bamIndexPath: nil,
            primaryAccession: "NC_123456.1",
            accessionLength: 1_000
        )
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view

        var capturedOrganism: TaxTriageOrganism?
        var capturedReadCount: Int?
        var capturedAccessions: [String]?
        vc.onBlastVerification = { organism, readCount, accessions, _, _ in
            capturedOrganism = organism
            capturedReadCount = readCount
            capturedAccessions = accessions
        }

        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while vc.testBatchFlatTableView.displayedRows.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, 1)
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(0)

        XCTAssertTrue(vc.testActionBar.blastButton.isEnabled)
        vc.testActionBar.blastButton.performClick(nil)

        XCTAssertEqual(capturedOrganism?.name, "Influenza A virus")
        XCTAssertEqual(capturedOrganism?.taxId, 11320)
        XCTAssertEqual(capturedOrganism?.reads, 37)
        XCTAssertEqual(capturedOrganism?.coverage, 82.5)
        XCTAssertEqual(capturedReadCount, 37)
        XCTAssertEqual(capturedAccessions, ["NC_123456.1"])
    }

    @MainActor func testExtractButtonDoesNotDispatchWithEmptySelectors() throws {
        // Regression test for AS24: presentUnifiedExtractionDialog() used to
        // dispatch buildTaxTriageSelectors()'s result unconditionally, even
        // when it returned []. A row with no primaryAccession produces no
        // accessions, so Extract Reads must not fire onExtractReadsRequested
        // for an empty selector list.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageExtractEmptySelectors-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let row = TaxTriageTaxonomyRow(
            sample: "sample-1",
            organism: "Unaccessioned organism",
            taxId: 99999,
            status: nil,
            tassScore: 0.5,
            readsAligned: 10,
            uniqueReads: 5,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: nil,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: nil,
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: nil,
            bamIndexPath: nil,
            primaryAccession: nil,
            accessionLength: nil
        )
        let db = try TaxTriageDatabase.create(at: dbURL, rows: [row], metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view

        var extractionRequestCount = 0
        vc.onExtractReadsRequested = { _, _, _, _ in
            extractionRequestCount += 1
        }

        vc.configureFromDatabase(db, resultURL: tempDir)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let deadline = Date().addingTimeInterval(5)
        while vc.testBatchFlatTableView.displayedRows.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, 1)
        vc.testBatchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(0)

        XCTAssertTrue(vc.testActionBar.extractButton.isEnabled)
        vc.testActionBar.extractButton.performClick(nil)

        XCTAssertEqual(extractionRequestCount, 0, "Extract Reads must not dispatch when there are no accessions to extract")
    }

    @MainActor func testDatabaseRowsLoadAsynchronouslyAfterInitialConfigure() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageLazyLoad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = (0..<25).map { index in
            TaxTriageTaxonomyRow(
                sample: "sample-1",
                organism: "Organism \(index)",
                taxId: 10_000 + index,
                status: nil,
                tassScore: 0.75,
                readsAligned: 10 + index,
                uniqueReads: 5 + index,
                pctReads: nil,
                pctAlignedReads: nil,
                coverageBreadth: nil,
                meanCoverage: nil,
                meanDepth: nil,
                confidence: nil,
                k2Reads: nil,
                parentK2Reads: nil,
                giniCoefficient: nil,
                meanBaseQ: nil,
                meanMapQ: nil,
                mapqScore: nil,
                disparityScore: nil,
                minhashScore: nil,
                diamondIdentity: nil,
                k2DisparityScore: nil,
                siblingsScore: nil,
                breadthWeightScore: nil,
                hhsPercentile: nil,
                isAnnotated: nil,
                annClass: nil,
                microbialCategory: nil,
                highConsequence: nil,
                isSpecies: nil,
                pathogenicSubstrains: nil,
                sampleType: nil,
                bamPath: nil,
                bamIndexPath: nil,
                primaryAccession: "NC_\(index)",
                accessionLength: 1000
            )
        }

        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        XCTAssertTrue(
            vc.testBatchFlatTableView.displayedRows.isEmpty,
            "configureFromDatabase should return before SQLite rows are paged into the viewport"
        )

        let deadline = Date().addingTimeInterval(10)
        while vc.testBatchFlatTableView.displayedRows.count < rows.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, rows.count)
    }

    @MainActor func testBatchMatrixExportWritesScientificProvenanceSidecar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageMatrixExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = [
            Self.taxonomyRow(sample: "sample-1", organism: "Alpha virus", taxId: 1001, tassScore: 0.91, reads: 42),
            Self.taxonomyRow(sample: "sample-2", organism: "Beta virus", taxId: 1002, tassScore: 0.82, reads: 24),
        ]
        let (vc, dbURL) = try makeConfiguredBatchController(tempDir: tempDir, rows: rows)

        let outputURL = tempDir.appendingPathComponent("organism-matrix.csv")
        try vc.writeBatchMatrixCSV(to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app taxtriage organism matrix export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.resolvedDefaults["metricCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.resolvedDefaults["sampleCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.resolvedDefaults["tableMode"]?.stringValue, "batchGroup")
        XCTAssertEqual(
            envelope.options.resolvedDefaults["sampleIds"]?.arrayValue?.compactMap(\.stringValue),
            ["sample-1", "sample-2"]
        )
        XCTAssertTrue(envelope.files.contains { $0.path == dbURL.path && $0.checksumSHA256 != nil })
    }

    @MainActor func testDelimitedResultsExportWritesScientificProvenanceSidecar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageResultsExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = [
            Self.taxonomyRow(sample: "sample-1", organism: "Alpha virus", taxId: 1001, tassScore: 0.91, reads: 42),
            Self.taxonomyRow(sample: "sample-2", organism: "Beta virus", taxId: 1002, tassScore: 0.82, reads: 24),
        ]
        let (vc, dbURL) = try makeConfiguredBatchController(tempDir: tempDir, rows: rows)
        vc.testOrganismTableView.rows = [
            TaxTriageTableRow(organism: "Alpha virus", tassScore: 0.91, reads: 42, uniqueReads: 21, taxId: 1001),
            TaxTriageTableRow(organism: "Beta virus", tassScore: 0.82, reads: 24, uniqueReads: 12, taxId: 1002),
        ]

        let outputURL = tempDir.appendingPathComponent("taxtriage-results.tsv")
        try vc.writeDelimitedResults(separator: "\t", fileExtension: "tsv", to: outputURL)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app taxtriage results export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["rowCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.resolvedDefaults["tableMode"]?.stringValue, "batchGroup")
        XCTAssertEqual(envelope.options.defaults["format"]?.stringValue, "tsv")
        XCTAssertEqual(envelope.options.explicit["format"]?.stringValue, "tsv")
        XCTAssertTrue(envelope.files.contains { $0.path == dbURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
    }

    @MainActor func testBatchReportExportWritesScientificProvenanceSidecar() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageReportExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rows = [
            Self.taxonomyRow(sample: "sample-1", organism: "Alpha virus", taxId: 1001, tassScore: 0.91, reads: 42),
            Self.taxonomyRow(sample: "sample-2", organism: "Beta virus", taxId: 1002, tassScore: 0.82, reads: 24),
        ]
        let (vc, dbURL) = try makeConfiguredBatchController(tempDir: tempDir, rows: rows)

        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "sample-1", fastq1: tempDir.appendingPathComponent("sample-1.fastq")),
                TaxTriageSample(sampleId: "sample-2", fastq1: tempDir.appendingPathComponent("sample-2.fastq")),
            ],
            outputDirectory: tempDir
        )
        let result = TaxTriageResult(
            config: config,
            runtime: 120.5,
            exitCode: 0,
            outputDirectory: tempDir
        )

        let outputURL = tempDir.appendingPathComponent("taxtriage-batch-report.txt")
        try vc.writeBatchReport(to: outputURL, result: result, config: config)

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app taxtriage batch report export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.checksumSHA256, try ProvenanceFileHasher.sha256(of: outputURL))
        XCTAssertEqual(envelope.output?.fileSize, try ProvenanceFileHasher.fileSize(of: outputURL))
        XCTAssertGreaterThan(envelope.options.resolvedDefaults["reportLineCount"]?.integerValue ?? 0, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["metricCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.resolvedDefaults["sampleCount"]?.integerValue, 2)
        XCTAssertEqual(envelope.options.resolvedDefaults["classifierCount"]?.integerValue, config.classifiers.count)
        XCTAssertEqual(envelope.options.resolvedDefaults["tableMode"]?.stringValue, "batchGroup")
        XCTAssertTrue(envelope.files.contains { $0.path == dbURL.path && $0.checksumSHA256 != nil && $0.fileSize != nil })
    }

    @MainActor private func makeConfiguredBatchController(
        tempDir: URL,
        rows: [TaxTriageTaxonomyRow]
    ) throws -> (TaxTriageResultViewController, URL) {
        let dbURL = tempDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase.create(at: dbURL, rows: rows, metadata: ["tool": "taxtriage"])

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.configureFromDatabase(db, resultURL: tempDir)

        let deadline = Date().addingTimeInterval(10)
        while vc.testBatchFlatTableView.displayedRows.count < rows.count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(vc.testBatchFlatTableView.displayedRows.count, rows.count)

        return (vc, dbURL)
    }

    private static func taxonomyRow(
        sample: String,
        organism: String,
        taxId: Int,
        tassScore: Double,
        reads: Int
    ) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample,
            organism: organism,
            taxId: taxId,
            status: nil,
            tassScore: tassScore,
            readsAligned: reads,
            uniqueReads: reads / 2,
            pctReads: nil,
            pctAlignedReads: nil,
            coverageBreadth: nil,
            meanCoverage: nil,
            meanDepth: nil,
            confidence: nil,
            k2Reads: nil,
            parentK2Reads: nil,
            giniCoefficient: nil,
            meanBaseQ: nil,
            meanMapQ: nil,
            mapqScore: nil,
            disparityScore: nil,
            minhashScore: nil,
            diamondIdentity: nil,
            k2DisparityScore: nil,
            siblingsScore: nil,
            breadthWeightScore: nil,
            hhsPercentile: nil,
            isAnnotated: nil,
            annClass: nil,
            microbialCategory: nil,
            highConsequence: nil,
            isSpecies: nil,
            pathogenicSubstrains: nil,
            sampleType: nil,
            bamPath: nil,
            bamIndexPath: nil,
            primaryAccession: "NC_\(taxId)",
            accessionLength: 1000
        )
    }

    @MainActor private static func metadataMenuTitles(in table: NSTableView) -> [String] {
        table.headerView?.menu?.items.compactMap { $0.representedObject as? String } ?? []
    }

    @MainActor private static func showMetadataColumn(named name: String, in table: NSTableView) throws {
        let menu = try XCTUnwrap(table.headerView?.menu)
        let index = try XCTUnwrap(menu.items.firstIndex {
            ($0.representedObject as? String) == name
        })
        menu.performActionForItem(at: index)
    }
}
