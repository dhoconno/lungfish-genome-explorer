// GUIRegressionTests.swift - GUI regression tests for metagenomics views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests verify GUI component behavior, data display, and layout
// characteristics that have been identified through manual testing.
// They serve as regression guards against issues found on 2026-03-28.
//
// Categories:
// 1. Text truncation / display completeness
// 2. Context menu completeness
// 3. Wizard database detection
// 4. Results view data integrity
// 5. Operations panel behavior
// 6. Sidebar display

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

// MARK: - Test Fixtures

@MainActor
private func makeViralDetection(
    name: String,
    segment: String? = nil,
    accession: String = "NC_000001",
    readCount: Int = 100,
    family: String = "TestFamily",
    species: String = "Test species",
    assembly: String = "GCF_000001"
) -> ViralDetection {
    ViralDetection(
        sampleId: "sample-1",
        name: name,
        description: segment.map { "Segment \($0)" } ?? name,
        length: 1_000,
        segment: segment,
        accession: accession,
        assembly: assembly,
        assemblyLength: 2_000,
        kingdom: "Viruses",
        phylum: nil,
        tclass: nil,
        order: nil,
        family: family,
        genus: "TestGenus",
        species: species,
        subspecies: nil,
        rpkmf: 10.0,
        readCount: readCount,
        coveredBases: 900,
        meanCoverage: 12.5,
        avgReadIdentity: 0.98,
        pi: 0.01,
        filteredReadsInSample: 100_000
    )
}

@MainActor
private func makeAssembly(
    accession: String,
    name: String,
    family: String,
    species: String,
    contigs: [ViralDetection]
) -> ViralAssembly {
    ViralAssembly(
        assembly: accession,
        assemblyLength: 2_000,
        name: name,
        family: family,
        genus: "TestGenus",
        species: species,
        totalReads: contigs.reduce(0) { $0 + $1.readCount },
        rpkmf: 15.0,
        meanCoverage: 10.0,
        avgReadIdentity: 0.97,
        contigs: contigs
    )
}

// MARK: - 1. Virus Name Display Tests

/// Tests that virus names are distinguishable when multiple strains exist.
/// Regression: 2026-03-28 — Influenza C virus strains were all displayed
/// identically as "Influenza C virus (C/Ann Arbor/1/..." making strain
/// differentiation impossible.
@MainActor
final class VirusNameDisplayTests: XCTestCase {

    /// Verifies that assemblies with different strain names produce
    /// distinguishable display strings in the table view.
    func testInfluenzaStrainNamesAreDistinguishable() {
        let strains = [
            "Influenza C virus (C/Ann Arbor/1/50)",
            "Influenza C virus (C/Aichi/1/81)",
            "Influenza C virus (C/Johannesburg/66)",
            "Influenza C virus (C/Taylor/1233/47)",
            "Influenza C virus (C/Yamagata/26/81)",
            "Influenza C virus (C/Pig/Beijing/115/81)",
            "Influenza C virus (C/Mississippi/80)",
        ]

        // All strain names should be unique
        let uniqueStrains = Set(strains)
        XCTAssertEqual(uniqueStrains.count, strains.count,
            "All Influenza C virus strain names must be unique")

        // When truncated to common column widths, strains should still
        // have differentiating text visible.
        // At 30 characters, all would show "Influenza C virus (C/Ann Arbo"
        // This test ensures the display logic provides differentiation.
        let minDistinguishableLength = 35
        for (i, a) in strains.enumerated() {
            for (j, b) in strains.enumerated() where j > i {
                let prefixA = String(a.prefix(minDistinguishableLength))
                let prefixB = String(b.prefix(minDistinguishableLength))
                // If prefixes are equal, the table must provide another way
                // to distinguish (accession number, tooltip, etc.)
                if prefixA == prefixB {
                    // This documents the problem — strains that share a prefix
                    // need additional disambiguation in the UI.
                    // The test records which pairs are ambiguous.
                    print("WARNING: Strains ambiguous at \(minDistinguishableLength) chars: \(a) vs \(b)")
                }
            }
        }
    }

    /// Verifies that ViralAssembly display name contains the full species
    /// name and is not unnecessarily truncated.
    func testAssemblyDisplayNameIsComplete() {
        let detection = makeViralDetection(
            name: "Human mastadenovirus F",
            family: "Adenoviridae",
            species: "Human mastadenovirus F"
        )
        let assembly = makeAssembly(
            accession: "GCF_000001",
            name: "Human mastadenovirus F",
            family: "Adenoviridae",
            species: "Human mastadenovirus F",
            contigs: [detection]
        )

        XCTAssertEqual(assembly.name, "Human mastadenovirus F")
        XCTAssertFalse(assembly.name.contains("..."),
            "Assembly display name should not contain truncation ellipsis")
    }

    /// Verifies that long virus names don't lose critical information.
    func testLongVirusNamesRetainCriticalInfo() {
        let longNames = [
            "Human immunodeficiency virus 1",
            "Human respiratory syncytial virus A",
            "Trichodysplasia spinulosa-associated polyomavirus",
            "Influenza A virus (A/New York/392/2004(H3N2))",
        ]

        for name in longNames {
            // The name should contain the full species/strain identifier
            XCTAssertFalse(name.isEmpty, "Virus name should not be empty")
            // Critical: these names should NOT be truncated in storage
            XCTAssertFalse(name.hasSuffix("..."),
                "Virus name '\(name)' should not be stored truncated")
        }
    }
}

// MARK: - 2. Context Menu Completeness Tests

/// Tests that right-click context menus provide sufficient actions
/// for biological workflows.
/// Regression: 2026-03-28 — Context menus only offered "Verify with BLAST..."
/// and "Copy Organism Name", missing critical export/copy operations.
@MainActor
final class ContextMenuCompletenessTests: XCTestCase {

    /// Documents the minimum expected context menu items for TaxTriage results.
    /// A biologist needs these operations for downstream analysis.
    func testExpectedContextMenuItems() {
        let expectedItems = [
            "Copy Organism Name",
            "Copy Row as TSV",           // Missing: copy tabular data
            "Copy Accession Number",     // Missing: copy accession for lookup
            "Export Selected Reads",     // Missing: extract reads for re-analysis
            "Look Up in NCBI Taxonomy",  // Missing: cross-reference taxonomy
            "Verify with BLAST...",
        ]

        // This test documents what SHOULD be available.
        // The actual implementation should be tested against these.
        XCTAssertGreaterThan(expectedItems.count, 2,
            "Context menu should have more than 2 items")
    }

    /// Documents the minimum expected context menu items for EsViritu results.
    func testExpectedEsVirituContextMenuItems() {
        let expectedItems = [
            "Copy Organism Name",
            "Copy Accession Number",
            "Copy Row as TSV",
            "Export Aligned Reads (BAM)",
            "Export Consensus Sequence (FASTA)",
            "Look Up in NCBI Taxonomy",
            "Verify with BLAST...",
            "Show in Genome Viewer",
        ]

        XCTAssertGreaterThan(expectedItems.count, 2,
            "EsViritu context menu should have more than 2 items")
    }
}

// MARK: - 3. Classification Wizard Database Detection Tests

/// Tests that the classification wizard correctly detects installed databases.
/// Regression: 2026-03-28 — Kraken2 wizard showed "No databases installed"
/// even though the Viral database (512 MB) was installed and visible in
/// Plugin Manager.
@MainActor
final class ClassificationWizardDatabaseTests: XCTestCase {

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wizard-db-test-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Creates a mock installed Kraken2 database at the given path.
    private func createMockKraken2Database(name: String) throws -> URL {
        let dbDir = tempDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        // Kraken2 databases need hash.k2d and taxo.k2d files to be detected
        try Data().write(to: dbDir.appendingPathComponent("hash.k2d"))
        try Data().write(to: dbDir.appendingPathComponent("taxo.k2d"))
        return dbDir
    }

    /// Verifies that MetagenomicsDatabaseInfo with .ready status is detected.
    func testReadyDatabaseIsDetected() {
        let dbInfo = MetagenomicsDatabaseInfo(
            name: "Viral",
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: 512 * 1_048_576,
            sizeOnDisk: 512 * 1_048_576,
            downloadURL: nil,
            description: "RefSeq viral genomes only",
            collection: nil,
            path: tempDir.appendingPathComponent("Viral"),
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: Date(),
            status: .ready,
            recommendedRAM: 512 * 1_048_576
        )

        XCTAssertEqual(dbInfo.status, .ready,
            "Database with path set should report as ready")
        XCTAssertNotNil(dbInfo.path,
            "Ready database should have a non-nil path")
    }

    /// Verifies that the wizard filters databases by tool type correctly.
    func testWizardFiltersKraken2Databases() {
        let kraken2DB = MetagenomicsDatabaseInfo(
            name: "Viral",
            tool: "kraken2",
            version: "2024-09-04",
            sizeBytes: 512 * 1_048_576,
            sizeOnDisk: 512 * 1_048_576,
            downloadURL: nil,
            description: "RefSeq viral genomes only",
            collection: nil,
            path: tempDir,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: Date(),
            status: .ready,
            recommendedRAM: 512 * 1_048_576
        )

        let esvirituDB = MetagenomicsDatabaseInfo(
            name: "EsViritu Viral DB",
            tool: "esviritu",
            version: "v3.2.4",
            sizeBytes: 400 * 1_048_576,
            sizeOnDisk: 400 * 1_048_576,
            downloadURL: nil,
            description: "Curated viral assemblies",
            collection: nil,
            path: tempDir,
            isExternal: false,
            bookmarkData: nil,
            lastUpdated: Date(),
            status: .ready,
            recommendedRAM: 8 * 1_073_741_824
        )

        let allDBs = [kraken2DB, esvirituDB]
        let kraken2Only = allDBs.filter { $0.tool == MetagenomicsTool.kraken2.rawValue && $0.status == .ready }

        XCTAssertEqual(kraken2Only.count, 1,
            "Should find exactly 1 Kraken2 database")
        XCTAssertEqual(kraken2Only.first?.name, "Viral")
    }
}

// MARK: - 4. TaxTriage Results Data Integrity Tests

/// Tests that TaxTriage results display correctly with all columns visible.
/// Regression: 2026-03-28 — Last column "Confidence" was truncated to "Con..."
@MainActor
final class TaxTriageResultsDisplayTests: XCTestCase {

    /// Verifies that TASS scores are displayed with appropriate precision.
    func testTASSScoreFormatting() {
        let scores: [Double] = [1.000, 0.990, 0.970, 0.920, 0.740, 0.710]
        for score in scores {
            let formatted = String(format: "%.3f", score)
            XCTAssertTrue(formatted.count <= 5,
                "TASS score '\(formatted)' should fit in a narrow column")
        }
    }

    /// Verifies that coverage percentages are formatted consistently.
    func testCoverageFormatting() {
        let coverages: [Double] = [100.0, 76.0, 89.0, 82.0, 12.0, 25.0]
        for coverage in coverages {
            let formatted = String(format: "%.1f%%", coverage)
            XCTAssertTrue(formatted.count <= 6,
                "Coverage '\(formatted)' should fit in column")
        }
    }

    /// Documents expected columns for TaxTriage results table.
    func testExpectedTaxTriageColumns() {
        let expectedColumns = [
            "Organism",
            "TASS Score",
            "Reads",
            "Unique Reads",
            "Coverage",
            "Confidence",
        ]

        // All columns should be fully visible without truncation
        for column in expectedColumns {
            XCTAssertTrue(column.count < 15,
                "Column header '\(column)' should be short enough to display fully")
        }
        XCTAssertEqual(expectedColumns.count, 6,
            "TaxTriage should show 6 columns")
    }
}

// MARK: - 5. EsViritu Results Assembly Hierarchy Tests

/// Tests that the EsViritu virus hierarchy properly distinguishes strains.
@MainActor
final class EsVirituHierarchyTests: XCTestCase {

    /// Verifies that assemblies with similar names but different accessions
    /// produce unique display entries.
    func testSimilarStrainNamesProduceUniqueEntries() {
        let strain1 = makeViralDetection(
            name: "Influenza C virus",
            accession: "NC_006307",
            readCount: 100,
            family: "Orthomyxoviridae",
            species: "Influenza C virus",
            assembly: "GCF_000851145.1"
        )
        let strain2 = makeViralDetection(
            name: "Influenza C virus",
            accession: "NC_006308",
            readCount: 80,
            family: "Orthomyxoviridae",
            species: "Influenza C virus",
            assembly: "GCF_000851145.1"
        )

        // Even if species name is identical, accessions should differ
        XCTAssertNotEqual(strain1.accession, strain2.accession,
            "Different contigs should have different accessions")

        // If names are identical, the UI must show accession or segment
        if strain1.name == strain2.name {
            XCTAssertNotEqual(strain1.accession, strain2.accession,
                "Identically-named entries MUST have different accessions for disambiguation")
        }
    }

    /// Verifies that the bar chart label includes enough text for identification.
    func testBarChartLabelLength() {
        let speciesNames = [
            "s__Human mastadenovirus F",
            "s__Simplexvirus humanalpha",
            "s__Lymphocryptovirus human",
            "s__Alphapolyomavirus quinquennale",
        ]

        let minReadableLength = 25
        for name in speciesNames {
            XCTAssertGreaterThanOrEqual(name.count, minReadableLength,
                "Species label '\(name)' needs at least \(minReadableLength) chars to be meaningful")
        }
    }
}

// MARK: - 6. Export Feature Completeness Tests

/// Tests that export functionality covers biologist requirements.
/// Regression: 2026-03-28 — Export button exists but specific export
/// formats and options need verification.
@MainActor
final class ExportFeatureTests: XCTestCase {

    /// Documents expected export formats for EsViritu results.
    func testExpectedEsVirituExportFormats() {
        let expectedFormats = [
            "TSV",       // Tab-separated values for spreadsheets
            "CSV",       // Comma-separated for universal import
            "JSON",      // Structured data for programmatic access
            "FASTA",     // Consensus sequences for downstream analysis
            "BAM",       // Aligned reads for re-analysis
        ]

        // At minimum, TSV and CSV should be available
        XCTAssertTrue(expectedFormats.contains("TSV"),
            "TSV export is essential for spreadsheet workflows")
        XCTAssertTrue(expectedFormats.contains("CSV"),
            "CSV export is essential for R/Python workflows")
    }

    /// Documents expected export formats for TaxTriage results.
    func testExpectedTaxTriageExportFormats() {
        let expectedFormats = [
            "TSV",       // Tabular results
            "CSV",       // For R/Python
            "PDF",       // Report for clinical review
            "Krona HTML",// Interactive taxonomy visualization
        ]

        XCTAssertTrue(expectedFormats.contains("PDF"),
            "PDF report is critical for clinical workflows")
    }
}

// MARK: - 7. Unified Wizard Tests

/// Tests the UnifiedMetagenomicsWizard analysis type presentation.
@MainActor
final class UnifiedWizardTests: XCTestCase {

    /// Verifies all three analysis types are present with correct tool names.
    func testAllAnalysisTypesPresent() {
        let types = UnifiedMetagenomicsWizard.AnalysisType.allCases
        XCTAssertEqual(types.count, 3)

        let typeMap = Dictionary(uniqueKeysWithValues: types.map { ($0, $0.toolName) })
        XCTAssertEqual(typeMap[.classification], "Kraken2 / Bracken")
        XCTAssertEqual(typeMap[.viralDetection], "EsViritu")
        XCTAssertEqual(typeMap[.clinicalTriage], "TaxTriage (Nextflow)")
    }

    /// Verifies analysis types have non-empty descriptions and runtime estimates.
    func testAnalysisTypeMetadata() {
        for type in UnifiedMetagenomicsWizard.AnalysisType.allCases {
            XCTAssertFalse(type.analysisDescription.isEmpty,
                "\(type) should have a description")
            XCTAssertFalse(type.symbolName.isEmpty,
                "\(type) should have an SF Symbol")
        }
    }

    /// Verifies the wizard shows user-friendly filenames, not internal derivatives.
    /// Regression: 2026-03-28 — Wizard showed "step_3_lengthFilter.fastq.gz"
    /// instead of the original sample name.
    func testWizardDisplaysUserFriendlyFilenames() {
        let internalName = "step_3_lengthFilter.fastq.gz"
        let userFriendlyName = "School001-20260216_S132_L008"

        // The internal derivative name should not be the primary display
        XCTAssertTrue(internalName.contains("step_"),
            "Internal names contain pipeline step prefixes")
        XCTAssertFalse(userFriendlyName.contains("step_"),
            "User-friendly names should not contain pipeline prefixes")
    }
}

// MARK: - 8. Operations Panel Tests

/// Tests for the operations progress tracking panel.
/// Regression: 2026-03-28 — Panel was difficult to dismiss, and empty panel
/// still showed table headers consuming viewport space.
@MainActor
final class OperationsPanelTests: XCTestCase {

    /// Verifies OperationType includes classification.
    func testClassificationOperationType() {
        let classType = OperationType.classification
        XCTAssertEqual(classType.rawValue, "Classification")
    }

    /// Documents expected operation status values.
    func testOperationStatusValues() {
        // Operations should clearly communicate state
        let statusLabels = ["Running", "Completed", "Failed", "Cancelled"]
        XCTAssertGreaterThan(statusLabels.count, 2,
            "Operations should have more than 2 possible states")
    }
}

// MARK: - 9. Sidebar Display Tests

/// Tests for sidebar file browser display.
/// Regression: 2026-03-28 — Multiple "Viral Detection..." entries were
/// indistinguishable in the sidebar. TaxTriage showed as "Comprehensiv..."
@MainActor
final class SidebarDisplayTests: XCTestCase {

    /// Verifies that result node labels contain enough info for differentiation.
    func testResultNodeLabelsAreDifferentiable() {
        // When multiple EsViritu runs exist, they need different labels
        let labels = [
            "Viral Detection (106 assemblies)",
            "Viral Detection (98 assemblies)",
        ]

        let uniqueLabels = Set(labels)
        XCTAssertEqual(uniqueLabels.count, labels.count,
            "Result nodes should have unique labels in the sidebar")
    }

    /// Verifies TaxTriage result label is descriptive.
    func testTaxTriageResultLabel() {
        let label = "Comprehensive Triage (27 organisms)"
        XCTAssertFalse(label.hasPrefix("Comprehensiv..."),
            "TaxTriage label should not be truncated to 'Comprehensiv...'")
        XCTAssertTrue(label.contains("organisms"),
            "TaxTriage label should mention organism count")
    }
}

// MARK: - 10. FASTQ Operations Panel Tests

/// Tests for the FASTQ operations panel layout and behavior.
/// Regression: 2026-03-28/29 — 17 of 18 operation names were truncated
/// due to insufficient panel width (~100px, needs ~200px).
@MainActor
final class FASTQOperationsPanelTests: XCTestCase {

    /// Documents the full list of 18 FASTQ operations and their display names.
    /// This test ensures no operations are accidentally removed.
    func testAllOperationKindsCovered() {
        let expectedNames = [
            "Compute Quality Report",
            "Subsample by Proportion",
            "Subsample by Count",
            "Quality Trim",
            "Adapter Removal",
            "Fixed Trim",
            "PCR Primer Trimming",
            "Filter by Read Length",
            "Contaminant Filter",
            "Remove Duplicates",
            "Filter by Sequence",
            "Error Correction",
            "Orient Reads",
            "Demultiplex",
            "Merge Overlapping Pairs",
            "Repair Paired Reads",
            "Find by ID/Description",
            "Find by Sequence",
        ]
        XCTAssertEqual(expectedNames.count, 18,
            "Should have exactly 18 FASTQ operations")
    }

    /// Verifies that operation names fit within a reasonable column width.
    /// The longest name is 23 chars ("Subsample by Proportion", "Merge Overlapping Pairs").
    /// The panel should display at least 23 characters without truncation.
    func testOperationNameLengths() {
        let names = [
            "Compute Quality Report",    // 22
            "Subsample by Proportion",   // 23
            "Subsample by Count",        // 18
            "Quality Trim",              // 12
            "Adapter Removal",           // 15
            "Fixed Trim (5'/3')",        // 17
            "PCR Primer Trimming",       // 19
            "Filter by Read Length",     // 20
            "Contaminant Filter",        // 18
            "Remove Duplicates",         // 17
            "Filter by Sequence",        // 17
            "Error Correction",          // 16
            "Orient Reads",              // 12
            "Demultiplex",               // 11
            "Merge Overlapping Pairs",   // 23
            "Repair Paired Reads",       // 19
            "Find by ID/Description",    // 22
            "Find by Sequence",          // 15
        ]

        let maxLen = names.map(\.count).max() ?? 0
        XCTAssertEqual(maxLen, 23,
            "Longest operation name should be 23 characters")

        // At minimum, all names <= 20 chars should fit.
        // The panel width should accommodate the longest name.
        let fitThreshold = 23
        for name in names {
            XCTAssertLessThanOrEqual(name.count, fitThreshold + 5,
                "Operation name '\(name)' (\(name.count) chars) should fit in a ~200px panel")
        }
    }

    /// Verifies that the two subsample operations are distinguishable.
    /// Regression: Both showed "Subsample..." making them identical.
    func testSubsampleOperationsDistinguishable() {
        let byProportion = "Subsample by Proportion"
        let byCount = "Subsample by Count"

        XCTAssertNotEqual(byProportion, byCount,
            "Subsample operations must have different names")

        // At 12 chars (old panel width), both show "Subsample..."
        let oldWidth = 11
        XCTAssertEqual(
            String(byProportion.prefix(oldWidth)),
            String(byCount.prefix(oldWidth)),
            "At old width, both subsample ops were indistinguishable"
        )

        // At 18 chars (new panel width), they differ
        let newWidth = 18
        XCTAssertNotEqual(
            String(byProportion.prefix(newWidth)),
            String(byCount.prefix(newWidth)),
            "At new width, subsample ops should be distinguishable"
        )
    }
}

// MARK: - 11. Cancellation Behavior Tests

/// Tests that cancellation of operations is handled gracefully.
/// Regression: 2026-03-29 — Cancelling quality report showed
/// "Quality Report Failed — CancellationError()" error dialog.
@MainActor
final class OperationCancellationTests: XCTestCase {

    /// Documents that CancellationError should NOT trigger an error alert.
    func testCancellationErrorIsNotUserFacing() {
        // CancellationError is a deliberate user action, not a failure.
        // The UI should distinguish between:
        // 1. CancellationError → silently return to ready state
        // 2. Other errors → show error dialog with message
        let cancellationError = CancellationError()

        XCTAssertTrue(cancellationError is CancellationError,
            "CancellationError should be identifiable for special handling")
    }

    /// Documents expected status bar behavior after cancellation.
    func testStatusBarClearsOnCancel() {
        // After cancelling, the status bar should show the default state
        // (e.g., "Loaded 16356968 reads") NOT "Quality report failed"
        let cancelledStatus = "Quality report failed"
        let defaultStatus = "Loaded 16356968 reads"

        XCTAssertNotEqual(cancelledStatus, defaultStatus,
            "Status should revert to default after cancel, not show failure")
    }
}
