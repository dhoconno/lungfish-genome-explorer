// MetagenomicsGapFixTests.swift - Tests for Phases G9-G10 metagenomics gap fixes
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

// MARK: - Test Helpers

/// Builds a taxonomy tree suitable for export and provenance tests.
///
/// Structure:
/// ```
/// root (taxId: 1, clade: 5000)
///   +-- Bacteria (taxId: 2, domain, clade: 4000, direct: 100)
///   |     +-- Escherichia coli (taxId: 562, species, clade: 2000, direct: 2000)
///   |     +-- Staphylococcus aureus (taxId: 1280, species, clade: 1000, direct: 1000)
///   +-- Viruses (taxId: 10239, domain, clade: 1000, direct: 1000)
/// ```
@MainActor
private func makeExportTestTree() -> TaxonTree {
    let root = TaxonNode(
        taxId: 1, name: "root", rank: .root, depth: 0,
        readsDirect: 0, readsClade: 5000, fractionClade: 1.0, fractionDirect: 0.0,
        parentTaxId: nil
    )

    let bacteria = TaxonNode(
        taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
        readsDirect: 100, readsClade: 4000, fractionClade: 0.8, fractionDirect: 0.02,
        parentTaxId: 1
    )
    bacteria.parent = root

    let ecoli = TaxonNode(
        taxId: 562, name: "Escherichia coli", rank: .species, depth: 2,
        readsDirect: 2000, readsClade: 2000, fractionClade: 0.4, fractionDirect: 0.4,
        parentTaxId: 2
    )
    ecoli.parent = bacteria

    let staph = TaxonNode(
        taxId: 1280, name: "Staphylococcus aureus", rank: .species, depth: 2,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 2
    )
    staph.parent = bacteria
    bacteria.children = [ecoli, staph]

    let viruses = TaxonNode(
        taxId: 10239, name: "Viruses", rank: .domain, depth: 1,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.2, fractionDirect: 0.2,
        parentTaxId: 1
    )
    viruses.parent = root
    root.children = [bacteria, viruses]

    let unclassified = TaxonNode(
        taxId: 0, name: "unclassified", rank: .unclassified, depth: 0,
        readsDirect: 1000, readsClade: 1000, fractionClade: 0.167, fractionDirect: 0.167,
        parentTaxId: nil
    )

    return TaxonTree(root: root, unclassifiedNode: unclassified, totalReads: 6000)
}

/// Creates a ClassificationResult for export and provenance testing.
@MainActor
private func makeExportTestResult(tree: TaxonTree? = nil) -> ClassificationResult {
    let tree = tree ?? makeExportTestTree()
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("export-test-\(UUID().uuidString)")

    let config = ClassificationConfig(
        inputFiles: [tempDir.appendingPathComponent("sample_reads.fastq")],
        isPairedEnd: false,
        databaseName: "Standard-8",
        databasePath: tempDir.appendingPathComponent("db"),
        confidence: 0.2,
        minimumHitGroups: 2,
        threads: 4,
        memoryMapping: false,
        outputDirectory: tempDir
    )

    return ClassificationResult(
        config: config,
        tree: tree,
        reportURL: tempDir.appendingPathComponent("classification.kreport"),
        outputURL: tempDir.appendingPathComponent("classification.kraken"),
        brackenURL: nil,
        runtime: 12.5,
        toolVersion: "2.1.3",
        provenanceId: UUID()
    )
}

// MARK: - Phase G9: Export Tests

@MainActor
final class TaxonomyExportTests: XCTestCase {

    // MARK: - CSV Export

    func testCSVExportHeader() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let csv = vc.buildDelimitedExport(tree: result.tree, separator: ",")
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertFalse(lines.isEmpty, "CSV export should have at least a header")
        XCTAssertEqual(
            lines[0],
            "Name,Rank,Reads (Clade),Reads (Direct),Clade %,Direct %"
        )
    }

    func testCSVExportContainsAllNodes() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let csv = vc.buildDelimitedExport(tree: result.tree, separator: ",")
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Header + root + Bacteria + E. coli + S. aureus + Viruses + unclassified = 7
        XCTAssertEqual(lines.count, 7, "Should have header + 5 tree nodes + 1 unclassified")

        // Verify specific taxon rows exist
        XCTAssertTrue(csv.contains("Escherichia coli"))
        XCTAssertTrue(csv.contains("Staphylococcus aureus"))
        XCTAssertTrue(csv.contains("Viruses"))
        XCTAssertTrue(csv.contains("Bacteria"))
        XCTAssertTrue(csv.contains("unclassified"))
    }

    func testCSVExportReadCounts() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let csv = vc.buildDelimitedExport(tree: result.tree, separator: ",")

        // E. coli has 2000 clade reads and 2000 direct reads
        XCTAssertTrue(csv.contains("Escherichia coli,Species,2000,2000"))

        // Root has 5000 clade, 0 direct
        XCTAssertTrue(csv.contains("root,Root,5000,0"))
    }

    func testCSVExportPercentages() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let csv = vc.buildDelimitedExport(tree: result.tree, separator: ",")
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }

        // E. coli: 2000/6000 = 33.3333%
        let ecoliLine = lines.first { $0.contains("Escherichia coli") }
        XCTAssertNotNil(ecoliLine)
        XCTAssertTrue(ecoliLine!.contains("33.3333"))
    }

    // MARK: - TSV Export

    func testTSVExportUsesTabSeparator() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let tsv = vc.buildDelimitedExport(tree: result.tree, separator: "\t")
        let firstLine = tsv.components(separatedBy: "\n").first!

        // Header should use tabs
        let tabs = firstLine.filter { $0 == "\t" }.count
        XCTAssertEqual(tabs, 5, "Header should have 5 tab separators (6 columns)")
    }

    func testTSVExportMatchesCSVNodeCount() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let csv = vc.buildDelimitedExport(tree: result.tree, separator: ",")
        let tsv = vc.buildDelimitedExport(tree: result.tree, separator: "\t")

        let csvLines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        let tsvLines = tsv.components(separatedBy: "\n").filter { !$0.isEmpty }

        XCTAssertEqual(csvLines.count, tsvLines.count, "CSV and TSV should have same row count")
    }

    // MARK: - Copy Summary

    func testCopySummaryContainsKeyInfo() throws {
        let result = makeExportTestResult()

        // The summary is on ClassificationResult, not the VC
        let summary = result.summary

        XCTAssertTrue(summary.contains("Classification Summary"))
        XCTAssertTrue(summary.contains("Standard-8"), "Should mention database name")
        XCTAssertTrue(summary.contains("6000"), "Should contain total reads")
        XCTAssertTrue(summary.contains("2.1.3"), "Should contain tool version")
        XCTAssertTrue(summary.contains("12.5"), "Should contain runtime")
        XCTAssertTrue(summary.contains("Species"), "Should mention species count")
    }

    // MARK: - Export Menu

    func testExportMenuHasExpectedItems() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let menu = vc.buildExportMenu()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertTrue(titles.contains("Export as CSV\u{2026}"))
        XCTAssertTrue(titles.contains("Export as TSV\u{2026}"))
        XCTAssertTrue(titles.contains("Copy Summary"))
        XCTAssertTrue(titles.contains("Show Provenance\u{2026}"))
    }

    func testExportMenuSeparatorCount() throws {
        let vc = TaxonomyViewController()
        _ = vc.view
        let result = makeExportTestResult()
        vc.configure(result: result)

        let menu = vc.buildExportMenu()
        let separators = menu.items.filter(\.isSeparatorItem).count
        XCTAssertEqual(separators, 2, "Should have 2 separators (CSV/TSV | Copy | Provenance)")
    }
}

// MARK: - Phase G9: Provenance Tests

@MainActor
final class TaxonomyProvenanceTests: XCTestCase {

    func testClassificationResultHasProvenance() {
        let result = makeExportTestResult()

        XCTAssertEqual(result.toolVersion, "2.1.3")
        XCTAssertEqual(result.config.databaseName, "Standard-8")
        XCTAssertEqual(result.config.confidence, 0.2)
        XCTAssertEqual(result.config.minimumHitGroups, 2)
        XCTAssertEqual(result.config.threads, 4)
        XCTAssertEqual(result.runtime, 12.5)
        XCTAssertNotNil(result.provenanceId)
    }

    func testClassificationResultAccessor() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        // Before configuration, result should be nil
        XCTAssertNil(vc.testClassificationResult)

        // After configuration, result should be available
        let result = makeExportTestResult()
        vc.configure(result: result)
        XCTAssertNotNil(vc.testClassificationResult)
        XCTAssertEqual(vc.testClassificationResult?.toolVersion, "2.1.3")
    }
}

// MARK: - Phase G10: Sunburst Right-Click Tests (Gap 24)

@MainActor
final class SunburstRightClickTests: XCTestCase {

    func testSunburstHasEmptySpaceCallback() {
        let sunburst = TaxonomySunburstView()

        var emptySpaceCalled = false
        sunburst.onEmptySpaceRightClicked = { _ in
            emptySpaceCalled = true
        }

        // Verify the callback is settable
        sunburst.onEmptySpaceRightClicked?(NSPoint.zero)
        XCTAssertTrue(emptySpaceCalled)
    }

    func testSunburstNodeRightClickCallbackExists() {
        let sunburst = TaxonomySunburstView()

        var nodeClickedTaxId: Int?
        sunburst.onNodeRightClicked = { node, _ in
            nodeClickedTaxId = node.taxId
        }

        let node = TaxonNode(
            taxId: 562, name: "E. coli", rank: .species, depth: 2,
            readsDirect: 100, readsClade: 100, fractionClade: 0.1, fractionDirect: 0.1,
            parentTaxId: 1
        )

        sunburst.onNodeRightClicked?(node, NSPoint.zero)
        XCTAssertEqual(nodeClickedTaxId, 562)
    }

    func testViewControllerWiresEmptySpaceCallback() throws {
        let vc = TaxonomyViewController()
        _ = vc.view

        let tree = makeExportTestTree()
        let result = makeExportTestResult(tree: tree)
        vc.configure(result: result)

        // The sunburst should have the empty space callback wired
        XCTAssertNotNil(vc.testSunburstView.onEmptySpaceRightClicked)
    }
}

// MARK: - Phase G10: RAM Warning Tests (Gap 19)

@MainActor
final class RAMWarningTests: XCTestCase {

    /// Creates a test database info with specified RAM requirements.
    private func makeDB(name: String, ramGB: Int64) -> MetagenomicsDatabaseInfo {
        MetagenomicsDatabaseInfo(
            name: name,
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: ramGB * 1_073_741_824,
            description: "Test DB",
            status: .ready,
            recommendedRAM: ramGB * 1_073_741_824
        )
    }

    func testSmallDatabaseDoesNotExceedRAM() {
        // 500 MB database should never exceed even 8 GB system RAM
        let db = makeDB(name: "Viral", ramGB: 0)
        let exceeds = ClassificationWizardSheet.databaseExceedsSystemRAM(
            db, systemRAM: 8 * 1_073_741_824
        )
        XCTAssertFalse(exceeds)
    }

    func testLargeDatabaseExceedsSmallRAM() {
        // 67 GB database vs 16 GB system
        let db = makeDB(name: "Standard", ramGB: 67)
        let exceeds = ClassificationWizardSheet.databaseExceedsSystemRAM(
            db, systemRAM: 16 * 1_073_741_824
        )
        XCTAssertTrue(exceeds)
    }

    func testDatabaseFitsInLargeRAM() {
        // 8 GB database vs 128 GB system
        let db = makeDB(name: "Standard-8", ramGB: 8)
        let exceeds = ClassificationWizardSheet.databaseExceedsSystemRAM(
            db, systemRAM: 128 * 1_073_741_824
        )
        XCTAssertFalse(exceeds)
    }

    func testRAMWarningTextContainsValues() {
        let db = makeDB(name: "Standard", ramGB: 67)
        let text = ClassificationWizardSheet.buildRAMWarningText(
            for: db,
            systemRAM: 16 * 1_073_741_824
        )

        XCTAssertTrue(text.contains("67"), "Should mention required GB")
        XCTAssertTrue(text.contains("16"), "Should mention available GB")
        XCTAssertTrue(text.contains("memory mapping"), "Should suggest memory mapping")
    }

    func testExactRAMBoundary() {
        // Database requires exactly the system RAM -- should not exceed
        let db = makeDB(name: "Standard-16", ramGB: 16)
        let exceeds = ClassificationWizardSheet.databaseExceedsSystemRAM(
            db, systemRAM: 16 * 1_073_741_824
        )
        XCTAssertFalse(exceeds, "Equal RAM should not trigger warning")
    }

    func testSlightlyOverRAM() {
        // Database requires 1 byte more than system RAM
        let db = MetagenomicsDatabaseInfo(
            name: "Test",
            tool: "kraken2",
            sizeBytes: 16 * 1_073_741_824 + 1,
            description: "Test",
            status: .ready,
            recommendedRAM: 16 * 1_073_741_824 + 1
        )
        let exceeds = ClassificationWizardSheet.databaseExceedsSystemRAM(
            db, systemRAM: 16 * 1_073_741_824
        )
        XCTAssertTrue(exceeds, "Exceeding by 1 byte should trigger warning")
    }
}

// MARK: - Phase G10: Auto Memory Mapping Tests (Gap 19 Extension)

final class AutoMemoryMappingTests: XCTestCase {

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("auto-mmap-test-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMemoryMappingAlreadyEnabled() async {
        let pipeline = ClassificationPipeline()

        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            databaseName: "Standard",
            databasePath: tempDir,
            memoryMapping: true, // already enabled
            outputDirectory: tempDir
        )

        let shouldEnable = await pipeline.shouldAutoEnableMemoryMapping(config: config)
        XCTAssertFalse(shouldEnable, "Should not re-enable when already enabled")
    }

    func testSmallDatabaseDoesNotTriggerAutoMapping() async {
        // Create a small database file
        let dbDir = tempDir.appendingPathComponent("small-db")
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        // Create a tiny hash.k2d file (100 bytes)
        try? Data(count: 100).write(to: dbDir.appendingPathComponent("hash.k2d"))

        let pipeline = ClassificationPipeline()
        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            databaseName: "Tiny",
            databasePath: dbDir,
            outputDirectory: tempDir
        )

        let shouldEnable = await pipeline.shouldAutoEnableMemoryMapping(config: config)
        XCTAssertFalse(shouldEnable, "Tiny database should not trigger memory mapping")
    }
}

// MARK: - Phase G10: Bracken Version Detection Tests (Gap 22)

final class BrackenVersionDetectionTests: XCTestCase {

    func testClassificationResultUsesSeparateVersions() {
        // Verify that ClassificationResult can hold a kraken2 version
        // (the bracken version is stored in provenance, not the result struct)
        let tempDir = FileManager.default.temporaryDirectory
        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("input.fastq")],
            isPairedEnd: false,
            databaseName: "Test",
            databasePath: tempDir,
            outputDirectory: tempDir
        )

        let root = TaxonNode(
            taxId: 1, name: "root", rank: .root, depth: 0,
            readsDirect: 0, readsClade: 100, fractionClade: 1.0, fractionDirect: 0.0,
            parentTaxId: nil
        )
        let tree = TaxonTree(root: root, unclassifiedNode: nil, totalReads: 100)

        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: tempDir.appendingPathComponent("report"),
            outputURL: tempDir.appendingPathComponent("output"),
            brackenURL: tempDir.appendingPathComponent("bracken"),
            runtime: 1.0,
            toolVersion: "2.1.3", // kraken2 version
            provenanceId: nil
        )

        XCTAssertEqual(result.toolVersion, "2.1.3")
        XCTAssertNotNil(result.brackenURL, "Bracken URL should be stored")
    }
}

// Note: Kraken2 progress parsing tests removed — parseKraken2ProgressLine is
// private to ClassificationPipeline. Progress parsing is implicitly tested
// during integration tests with real kraken2 execution.
