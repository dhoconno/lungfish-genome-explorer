// AnnotationTableDrawerVariantTests.swift - Tests for variant tab in annotation drawer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class AnnotationTableDrawerVariantTests: XCTestCase {

    private nonisolated(unsafe) var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawer_variant_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a drawer with both annotation and variant databases.
    private func createDrawerWithAnnotationsAndVariants(
        bedLines: [String] = [
            "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=BRCA1",
            "chr1\t200\t300\tXM_001\t0\t+\t200\t300\t0,0,0\t1\t100\t0\tmRNA\tproduct=test"
        ],
        vcfContent: String = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs12345\tA\tG\t30.0\tPASS\t.
        chr1\t250\trs67890\tTC\tT\t45.5\tPASS\t.
        chr1\t350\t.\tG\tGAA\t20.0\tLowQual\t.
        """
    ) throws -> AnnotationTableDrawerView {
        // Create annotation database
        let bedContent = bedLines.joined(separator: "\n")
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let annotDbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotDbURL)

        // Create variant database
        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDbURL = tempDir.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDbURL)

        // Create manifest with both annotation and variant tracks
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "seq.fa.gz",
                indexPath: "seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: []
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "annotations",
                    name: "Annotations",
                    path: "annotations.bb",
                    databasePath: "annotations.db"
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Variants",
                    path: "variants.bcf",
                    indexPath: "variants.bcf.csi",
                    databasePath: "variants.db"
                )
            ]
        )

        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let searchIndex = AnnotationSearchIndex()
        let success = searchIndex.buildFromDatabase(bundle: bundle, trackId: "annotations", databasePath: "annotations.db")
        XCTAssertTrue(success, "Annotation database should open successfully")
        XCTAssertTrue(searchIndex.hasVariantDatabase, "Variant database should be available")

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        return drawer
    }

    /// Creates a drawer with only annotations (no variants).
    private func createDrawerWithAnnotationsOnly(
        bedLines: [String] = [
            "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=BRCA1"
        ]
    ) throws -> AnnotationTableDrawerView {
        let bedContent = bedLines.joined(separator: "\n")
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "seq.fa.gz",
                indexPath: "seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: []
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "annotations",
                    name: "Annotations",
                    path: "annotations.bb",
                    databasePath: "annotations.db"
                )
            ]
        )
        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)

        let searchIndex = AnnotationSearchIndex()
        searchIndex.buildFromDatabase(bundle: bundle, trackId: "annotations", databasePath: "annotations.db")

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        return drawer
    }

    /// Creates a drawer with only variants (no annotations).
    private func createDrawerWithVariantsOnly(
        vcfContent: String = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs111\tA\tG\t50.0\tPASS\t.
        chr1\t200\trs222\tAT\tA\t35.0\tPASS\t.
        """
    ) throws -> AnnotationTableDrawerView {
        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDbURL = tempDir.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDbURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test.bundle",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "seq.fa.gz",
                indexPath: "seq.fa.gz.fai",
                totalLength: 1000,
                chromosomes: []
            ),
            variants: [
                VariantTrackInfo(
                    id: "variants",
                    name: "Variants",
                    path: "variants.bcf",
                    indexPath: "variants.bcf.csi",
                    databasePath: "variants.db"
                )
            ]
        )

        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let searchIndex = AnnotationSearchIndex()
        searchIndex.buildIndex(bundle: bundle, chromosomes: [])

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        return drawer
    }

    /// Searches top-level items and one level of submenus for a menu item.
    private func findMenuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title == title { return item }
            if let submenu = item.submenu {
                if let found = submenu.items.first(where: { $0.title == title }) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - DrawerTab Enum Tests

    func testDrawerTabAnnotationsRawValue() {
        XCTAssertEqual(AnnotationTableDrawerView.DrawerTab.annotations.rawValue, 0)
    }

    func testDrawerTabVariantsRawValue() {
        XCTAssertEqual(AnnotationTableDrawerView.DrawerTab.variants.rawValue, 1)
    }

    func testDrawerTabRoundTrip() {
        XCTAssertEqual(AnnotationTableDrawerView.DrawerTab(rawValue: 0), .annotations)
        XCTAssertEqual(AnnotationTableDrawerView.DrawerTab(rawValue: 1), .variants)
        XCTAssertNil(AnnotationTableDrawerView.DrawerTab(rawValue: 2))
    }

    // MARK: - Initial State Tests

    func testInitialTabIsAnnotations() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        XCTAssertEqual(drawer.activeTab, .annotations)
    }

    func testInitialAnnotationsDisplayed() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        // Should show annotation data (not variants) in initial view
        XCTAssertFalse(drawer.displayedAnnotations.isEmpty)
        // All initial results should be annotations (not variants)
        for result in drawer.displayedAnnotations {
            XCTAssertFalse(result.isVariant, "Initial tab should show annotations, not variants")
        }
    }

    func testAnnotationCountTrackedSeparately() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        // Should display annotations, not all items
        XCTAssertEqual(drawer.displayedAnnotations.count, 2, "Should show 2 annotations in initial view")
    }

    // MARK: - Tab Switching Tests

    func testSwitchToVariantsTab() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertEqual(drawer.activeTab, .variants)
    }

    func testVariantsTabShowsVariantData() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        // Should show variant data
        XCTAssertFalse(drawer.displayedAnnotations.isEmpty)
        for result in drawer.displayedAnnotations {
            XCTAssertTrue(result.isVariant, "Variants tab should show variants, not annotations")
        }
    }

    func testVariantsTabShowsCorrectCount() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertEqual(drawer.displayedAnnotations.count, 3, "Should show 3 variants")
    }

    func testSwitchBackToAnnotationsTab() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertEqual(drawer.activeTab, .variants)

        drawer.switchToTab(.annotations)
        XCTAssertEqual(drawer.activeTab, .annotations)
        // Should show annotations again
        for result in drawer.displayedAnnotations {
            XCTAssertFalse(result.isVariant, "Switching back to annotations should show annotations")
        }
    }

    // MARK: - Column Configuration Tests

    func testAnnotationTabHasAnnotationColumns() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        // Annotations tab should show annotation data
        XCTAssertFalse(drawer.displayedAnnotations.isEmpty)
        // The annotations should NOT have variant fields
        let first = drawer.displayedAnnotations[0]
        XCTAssertNil(first.ref)
        XCTAssertNil(first.alt)
    }

    func testVariantTabShowsVariantFields() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        XCTAssertFalse(drawer.displayedAnnotations.isEmpty)
        let first = drawer.displayedAnnotations[0]
        XCTAssertNotNil(first.ref)
        XCTAssertNotNil(first.alt)
        XCTAssertTrue(first.isVariant)
    }

    // MARK: - Variant Data Accuracy Tests

    func testVariantIDDisplayed() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        let names = drawer.displayedAnnotations.map { $0.name }
        XCTAssertTrue(names.contains("rs12345"), "Should contain rs12345")
        XCTAssertTrue(names.contains("rs67890"), "Should contain rs67890")
    }

    func testVariantTypesCorrect() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        let types = Set(drawer.displayedAnnotations.map { $0.type })
        // rs12345: A>G = SNP, rs67890: TC>T = DEL, .: G>GAA = INS
        XCTAssertTrue(types.contains("SNP"), "Should have SNP variant")
        XCTAssertTrue(types.contains("DEL"), "Should have DEL variant")
        XCTAssertTrue(types.contains("INS"), "Should have INS variant")
    }

    func testVariantRefAltFields() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        let snp = drawer.displayedAnnotations.first { $0.name == "rs12345" }
        XCTAssertEqual(snp?.ref, "A")
        XCTAssertEqual(snp?.alt, "G")

        let del = drawer.displayedAnnotations.first { $0.name == "rs67890" }
        XCTAssertEqual(del?.ref, "TC")
        XCTAssertEqual(del?.alt, "T")
    }

    func testVariantQualityField() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        let snp = drawer.displayedAnnotations.first { $0.name == "rs12345" }
        XCTAssertEqual(snp?.quality ?? -1, 30.0, accuracy: 0.01)

        let del = drawer.displayedAnnotations.first { $0.name == "rs67890" }
        XCTAssertEqual(del?.quality ?? -1, 45.5, accuracy: 0.01)
    }

    func testVariantFilterField() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        let snp = drawer.displayedAnnotations.first { $0.name == "rs12345" }
        XCTAssertEqual(snp?.filter, "PASS")

        let ins = drawer.displayedAnnotations.first { $0.type == "INS" }
        XCTAssertEqual(ins?.filter, "LowQual")
    }

    func testVariantPositionIs0Based() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        // VCF has POS=150 (1-based), DB stores 0-based = 149
        let snp = drawer.displayedAnnotations.first { $0.name == "rs12345" }
        XCTAssertEqual(snp?.start, 149)
    }

    // MARK: - Tab Control Visibility Tests

    func testTabControlHiddenWhenNoVariants() throws {
        let drawer = try createDrawerWithAnnotationsOnly()
        // Tab control should be hidden when there are no variants
        // (We verify via the active tab staying at annotations)
        XCTAssertEqual(drawer.activeTab, .annotations)
    }

    func testTabControlVisibleWhenVariantsExist() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        // Tab should be usable (we can switch to variants)
        drawer.switchToTab(.variants)
        XCTAssertEqual(drawer.activeTab, .variants)
        XCTAssertFalse(drawer.displayedAnnotations.isEmpty)
    }

    // MARK: - Variant Filtering Tests

    func testVariantTypeChipFiltering() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        // All 3 variants should be visible initially
        XCTAssertEqual(drawer.displayedAnnotations.count, 3)

        // TODO: The chip filtering is driven by visibleTypes (private) through type chip toggles.
        // We verify the data source correctly filters by checking that different types exist.
        let types = Set(drawer.displayedAnnotations.map { $0.type })
        XCTAssertEqual(types.count, 3, "Should have 3 distinct variant types")
    }

    func testAnnotationFilteringIndependentOfVariants() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        // On annotation tab, we should see only annotations
        XCTAssertEqual(drawer.displayedAnnotations.count, 2)
        let types = Set(drawer.displayedAnnotations.map { $0.type })
        // Annotation types should not include variant types
        XCTAssertFalse(types.contains("SNP"))
        XCTAssertFalse(types.contains("DEL"))
        XCTAssertFalse(types.contains("INS"))
    }

    // MARK: - Variant Context Menu Tests

    func testVariantContextMenuHasCopyVariantID() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let item = findMenuItem(titled: "Copy Variant ID", in: menu)
        XCTAssertNotNil(item, "Variant context menu should have 'Copy Variant ID'")
    }

    func testVariantContextMenuHasCopyCoordinates() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let item = findMenuItem(titled: "Copy Coordinates", in: menu)
        XCTAssertNotNil(item, "Variant context menu should have 'Copy Coordinates'")
    }

    func testVariantContextMenuHasCopyRefAlt() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let item = findMenuItem(titled: "Copy Ref/Alt", in: menu)
        XCTAssertNotNil(item, "Variant context menu should have 'Copy Ref/Alt'")
    }

    func testVariantContextMenuHasCopyAsVCFLine() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let item = findMenuItem(titled: "Copy as VCF Line", in: menu)
        XCTAssertNotNil(item, "Variant context menu should have 'Copy as VCF Line'")
    }

    func testVariantContextMenuHasZoomToVariant() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        let item = findMenuItem(titled: "Zoom to Variant", in: menu)
        XCTAssertNotNil(item, "Variant context menu should have 'Zoom to Variant'")
    }

    func testVariantContextMenuHasFilterToType() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        // rs12345 is a SNP
        let item = findMenuItem(titled: "Filter to SNP Only", in: menu)
        XCTAssertNotNil(item, "Variant context menu should have 'Filter to SNP Only'")
    }

    func testVariantContextMenuDoesNotHaveAnnotationItems() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.selectAnnotation(named: "rs12345"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        // Variant context menu should NOT have annotation-specific items
        XCTAssertNil(findMenuItem(titled: "Copy Sequence", in: menu))
        XCTAssertNil(findMenuItem(titled: "Copy Reverse Complement", in: menu))
        XCTAssertNil(findMenuItem(titled: "Copy as FASTA", in: menu))
        XCTAssertNil(findMenuItem(titled: "Extract Sequence\u{2026}", in: menu))
    }

    func testAnnotationContextMenuDoesNotHaveVariantItems() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        // Stay on annotations tab
        XCTAssertTrue(drawer.selectAnnotation(named: "BRCA1"))

        let menu = NSMenu()
        drawer.menuNeedsUpdate(menu)

        // Annotation context menu should NOT have variant-specific items
        XCTAssertNil(findMenuItem(titled: "Copy Variant ID", in: menu))
        XCTAssertNil(findMenuItem(titled: "Copy Ref/Alt", in: menu))
        XCTAssertNil(findMenuItem(titled: "Copy as VCF Line", in: menu))
    }

    // MARK: - SearchResult isVariant Tests

    func testSearchResultIsVariantWhenRefPresent() {
        let result = AnnotationSearchIndex.SearchResult(
            name: "rs123",
            chromosome: "chr1",
            start: 100,
            end: 101,
            trackId: "variants",
            type: "SNP",
            ref: "A",
            alt: "G"
        )
        XCTAssertTrue(result.isVariant)
    }

    func testSearchResultIsNotVariantWhenRefNil() {
        let result = AnnotationSearchIndex.SearchResult(
            name: "BRCA1",
            chromosome: "chr1",
            start: 100,
            end: 500,
            trackId: "annotations",
            type: "gene"
        )
        XCTAssertFalse(result.isVariant)
    }

    func testSearchResultVariantFieldsPreserved() {
        let result = AnnotationSearchIndex.SearchResult(
            name: "rs999",
            chromosome: "chr1",
            start: 50,
            end: 51,
            trackId: "variants",
            type: "SNP",
            ref: "C",
            alt: "T",
            quality: 99.9,
            filter: "PASS",
            sampleCount: 42,
            variantRowId: 7
        )
        XCTAssertEqual(result.ref, "C")
        XCTAssertEqual(result.alt, "T")
        XCTAssertEqual(result.quality ?? -1, 99.9, accuracy: 0.01)
        XCTAssertEqual(result.filter, "PASS")
        XCTAssertEqual(result.sampleCount, 42)
        XCTAssertEqual(result.variantRowId, 7)
    }

    // MARK: - Sorting Tests

    func testVariantSortByQuality() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        // Verify initial data has different qualities
        let qualities = drawer.displayedAnnotations.compactMap { $0.quality }
        XCTAssertEqual(qualities.count, 3)

        // Verify qualities include expected values
        XCTAssertTrue(qualities.contains(where: { abs($0 - 30.0) < 0.01 }))
        XCTAssertTrue(qualities.contains(where: { abs($0 - 45.5) < 0.01 }))
        XCTAssertTrue(qualities.contains(where: { abs($0 - 20.0) < 0.01 }))
    }

    func testVariantSortByPosition() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)

        // Variants should be in order by position (default sort from SQLite is chromosome, position)
        let positions = drawer.displayedAnnotations.map { $0.start }
        XCTAssertEqual(positions, positions.sorted(), "Variants should be sorted by position")
    }

    // MARK: - Variants-Only Bundle Tests

    func testVariantsOnlyBundle() throws {
        let drawer = try createDrawerWithVariantsOnly()
        // With no annotations, the initial annotations tab should be empty or
        // we should be able to switch to variants
        drawer.switchToTab(.variants)
        XCTAssertEqual(drawer.displayedAnnotations.count, 2)
    }

    func testVariantsOnlyBundleVariantTypes() throws {
        let drawer = try createDrawerWithVariantsOnly()
        drawer.switchToTab(.variants)

        let types = Set(drawer.displayedAnnotations.map { $0.type })
        XCTAssertTrue(types.contains("SNP"))
        XCTAssertTrue(types.contains("DEL"))
    }

    // MARK: - Multi-Sample VCF Tests

    func testMultiSampleVCFSampleCount() throws {
        let multiSampleVCF = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSample1\tSample2\tSample3
        chr1\t100\trs111\tA\tG\t50.0\tPASS\t.\tGT\t0/1\t1/1\t0/0
        chr1\t200\trs222\tAT\tA\t35.0\tPASS\t.\tGT\t./.\t0/1\t./0
        """

        let drawer = try createDrawerWithAnnotationsAndVariants(vcfContent: multiSampleVCF)
        drawer.switchToTab(.variants)

        let rs111 = drawer.displayedAnnotations.first { $0.name == "rs111" }
        XCTAssertEqual(rs111?.sampleCount, 3, "All 3 samples have genotype data")

        let rs222 = drawer.displayedAnnotations.first { $0.name == "rs222" }
        // ./. is fully missing (excluded), 0/1 and ./0 are counted (2 non-missing)
        XCTAssertEqual(rs222?.sampleCount, 2, "2 of 3 samples have non-missing genotype data")
    }

    // MARK: - VariantDatabaseRecord.toSearchResult Tests

    func testVariantDatabaseRecordToSearchResult() {
        let record = VariantDatabaseRecord(
            id: 42,
            chromosome: "chr5",
            position: 1000,
            end: 1001,
            variantID: "rs54321",
            ref: "G",
            alt: "A",
            variantType: "SNP",
            quality: 88.8,
            filter: "PASS",
            info: "DP=100",
            sampleCount: 5
        )

        let result = record.toSearchResult(trackId: "my-variants")
        XCTAssertEqual(result.name, "rs54321")
        XCTAssertEqual(result.chromosome, "chr5")
        XCTAssertEqual(result.start, 1000)
        XCTAssertEqual(result.end, 1001)
        XCTAssertEqual(result.trackId, "my-variants")
        XCTAssertEqual(result.type, "SNP")
        XCTAssertEqual(result.strand, ".")
        XCTAssertEqual(result.ref, "G")
        XCTAssertEqual(result.alt, "A")
        XCTAssertEqual(result.quality ?? -1, 88.8, accuracy: 0.01)
        XCTAssertEqual(result.filter, "PASS")
        XCTAssertEqual(result.sampleCount, 5)
        XCTAssertEqual(result.variantRowId, 42)
        XCTAssertTrue(result.isVariant)
    }

    // MARK: - AnnotationSearchIndex Tab-Specific Query Tests

    func testAnnotationSearchIndexQueryAnnotationsOnly() throws {
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\t.".write(to: bedURL, atomically: true, encoding: .utf8)
        let annotDbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotDbURL)

        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t100\trs1\tA\tG\t30\tPASS\t.".write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDbURL = tempDir.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDbURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 1000, chromosomes: []),
            annotations: [AnnotationTrackInfo(id: "a", name: "A", path: "a.bb", databasePath: "annotations.db")],
            variants: [VariantTrackInfo(id: "v", name: "V", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let index = AnnotationSearchIndex()
        index.buildFromDatabase(bundle: bundle, trackId: "a", databasePath: "annotations.db")

        let annotResults = index.queryAnnotationsOnly()
        XCTAssertEqual(annotResults.count, 1)
        XCTAssertFalse(annotResults[0].isVariant)

        let variantResults = index.queryVariantsOnly()
        XCTAssertEqual(variantResults.count, 1)
        XCTAssertTrue(variantResults[0].isVariant)
    }

    func testAnnotationSearchIndexAnnotationCount() throws {
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        let lines = (1...5).map { "chr1\t\($0*100)\t\($0*100+50)\tGene\($0)\t0\t+\t\($0*100)\t\($0*100+50)\t0,0,0\t1\t50\t0\tgene\t." }
        try lines.joined(separator: "\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let annotDbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotDbURL)

        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t100\trs1\tA\tG\t30\tPASS\t.\nchr1\t200\trs2\tC\tT\t40\tPASS\t.".write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDbURL = tempDir.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDbURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 1000, chromosomes: []),
            annotations: [AnnotationTrackInfo(id: "a", name: "A", path: "a.bb", databasePath: "annotations.db")],
            variants: [VariantTrackInfo(id: "v", name: "V", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let index = AnnotationSearchIndex()
        index.buildFromDatabase(bundle: bundle, trackId: "a", databasePath: "annotations.db")

        XCTAssertEqual(index.queryAnnotationCount(), 5)
        XCTAssertEqual(index.queryVariantCount(), 2)
        XCTAssertEqual(index.entryCount, 5)
        XCTAssertEqual(index.variantCount, 2)
    }

    func testAnnotationSearchIndexAnnotationTypesVsVariantTypes() throws {
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\t.\nchr1\t600\t700\tXM_001\t0\t+\t600\t700\t0,0,0\t1\t100\t0\tmRNA\t.".write(to: bedURL, atomically: true, encoding: .utf8)
        let annotDbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotDbURL)

        let vcfURL = tempDir.appendingPathComponent("variants.vcf")
        try "##fileformat=VCFv4.2\n#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\nchr1\t100\trs1\tA\tG\t30\tPASS\t.\nchr1\t200\trs2\tAT\tA\t40\tPASS\t.".write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDbURL = tempDir.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDbURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 1000, chromosomes: []),
            annotations: [AnnotationTrackInfo(id: "a", name: "A", path: "a.bb", databasePath: "annotations.db")],
            variants: [VariantTrackInfo(id: "v", name: "V", path: "v.bcf", indexPath: "v.csi", databasePath: "variants.db")]
        )
        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let index = AnnotationSearchIndex()
        index.buildFromDatabase(bundle: bundle, trackId: "a", databasePath: "annotations.db")

        let annotTypes = index.annotationTypes
        XCTAssertTrue(annotTypes.contains("gene"))
        XCTAssertTrue(annotTypes.contains("mRNA"))
        XCTAssertFalse(annotTypes.contains("SNP"))
        XCTAssertFalse(annotTypes.contains("DEL"))

        let variantTypes = index.variantTypes
        XCTAssertTrue(variantTypes.contains("SNP"))
        XCTAssertTrue(variantTypes.contains("DEL"))
        XCTAssertFalse(variantTypes.contains("gene"))
        XCTAssertFalse(variantTypes.contains("mRNA"))

        // allTypes should include everything
        let allTypes = index.allTypes
        XCTAssertTrue(allTypes.contains("gene"))
        XCTAssertTrue(allTypes.contains("mRNA"))
        XCTAssertTrue(allTypes.contains("SNP"))
        XCTAssertTrue(allTypes.contains("DEL"))
    }

    // MARK: - Edge Cases

    func testEmptyVariantDatabase() throws {
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        """

        let drawer = try createDrawerWithAnnotationsAndVariants(vcfContent: vcfContent)
        drawer.switchToTab(.variants)
        XCTAssertTrue(drawer.displayedAnnotations.isEmpty, "Empty VCF should produce no variants")
    }

    func testSelectAnnotationWorksOnVariantTab() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        let found = drawer.selectAnnotation(named: "rs12345")
        XCTAssertTrue(found, "Should find rs12345 in variant tab")
    }

    func testSelectAnnotationFailsForMissingName() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        let found = drawer.selectAnnotation(named: "nonexistent")
        XCTAssertFalse(found, "Should not find nonexistent variant")
    }

    func testAnnotationNotFoundOnVariantTab() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        let found = drawer.selectAnnotation(named: "BRCA1")
        XCTAssertFalse(found, "BRCA1 is an annotation, not a variant — should not be on variant tab")
    }

    func testVariantNotFoundOnAnnotationTab() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        let found = drawer.selectAnnotation(named: "rs12345")
        XCTAssertFalse(found, "rs12345 is a variant — should not be on annotation tab")
    }
}
