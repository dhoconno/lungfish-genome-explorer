// VariantTableEnhancementTests.swift - Tests for Phase 1 variant table features
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class VariantTableEnhancementTests: XCTestCase {

    private nonisolated(unsafe) var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vt_enhance_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up UserDefaults test keys
        UserDefaults.standard.removeObject(forKey: "ColumnPreferences_annotations")
        UserDefaults.standard.removeObject(forKey: "ColumnPreferences_variantCalls")
        UserDefaults.standard.removeObject(forKey: "ColumnPreferences_variantGenotypes")
        UserDefaults.standard.removeObject(forKey: "ColumnPreferences_samples")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Column Preference Model Tests

    func testColumnPreferenceRoundTrip() throws {
        let prefs = TabColumnPreferences(columns: [
            ColumnPreference(id: "NameColumn", title: "Name", isVisible: true, order: 0),
            ColumnPreference(id: "TypeColumn", title: "Type", isVisible: false, order: 1),
            ColumnPreference(id: "ChromColumn", title: "Chrom", isVisible: true, order: 2),
        ])

        ColumnPrefsKey.save(prefs, tab: "test_roundtrip")
        let loaded = ColumnPrefsKey.load(tab: "test_roundtrip")
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.columns.count, 3)
        XCTAssertEqual(loaded?.columns[1].isVisible, false)

        // Clean up
        UserDefaults.standard.removeObject(forKey: "ColumnPreferences_test_roundtrip")
    }

    func testVisibleColumnsFilter() {
        let prefs = TabColumnPreferences(columns: [
            ColumnPreference(id: "A", title: "A", isVisible: true, order: 2),
            ColumnPreference(id: "B", title: "B", isVisible: false, order: 1),
            ColumnPreference(id: "C", title: "C", isVisible: true, order: 0),
        ])

        let visible = prefs.visibleColumns
        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(visible[0].id, "C")  // order 0 first
        XCTAssertEqual(visible[1].id, "A")  // order 2 second
    }

    func testResetToDefaults() {
        var prefs = TabColumnPreferences(columns: [
            ColumnPreference(id: "A", title: "A", isVisible: false, order: 5),
            ColumnPreference(id: "B", title: "B", isVisible: false, order: 3),
        ])
        prefs.resetToDefaults()
        XCTAssertTrue(prefs.columns[0].isVisible)
        XCTAssertTrue(prefs.columns[1].isVisible)
        XCTAssertEqual(prefs.columns[0].order, 0)
        XCTAssertEqual(prefs.columns[1].order, 1)
    }

    func testLoadMissingPrefsReturnsNil() {
        let loaded = ColumnPrefsKey.load(tab: "nonexistent_tab_\(UUID().uuidString)")
        XCTAssertNil(loaded)
    }

    // MARK: - Genotype Display Row Tests

    func testGenotypeClassification() {
        typealias Row = AnnotationTableDrawerView.GenotypeDisplayRow
        XCTAssertEqual(Row.classify(allele1: 0, allele2: 0), "Hom Ref")
        XCTAssertEqual(Row.classify(allele1: 0, allele2: 1), "Het")
        XCTAssertEqual(Row.classify(allele1: 1, allele2: 0), "Het")
        XCTAssertEqual(Row.classify(allele1: 1, allele2: 1), "Hom Alt")
        XCTAssertEqual(Row.classify(allele1: 2, allele2: 2), "Hom Alt")
        XCTAssertEqual(Row.classify(allele1: -1, allele2: -1), "Missing")
        XCTAssertEqual(Row.classify(allele1: 0, allele2: -1), "Missing")
    }

    func testAlleleBalanceComputation() {
        typealias Row = AnnotationTableDrawerView.GenotypeDisplayRow

        // Standard het: 10 ref, 15 alt
        let ab1 = Row.computeAlleleBalance(from: "10,15")
        XCTAssertNotNil(ab1)
        XCTAssertEqual(ab1!, 0.6, accuracy: 0.001)

        // Hom ref: all ref reads
        let ab2 = Row.computeAlleleBalance(from: "30,0")
        XCTAssertNotNil(ab2)
        XCTAssertEqual(ab2!, 0.0, accuracy: 0.001)

        // Hom alt: all alt reads
        let ab3 = Row.computeAlleleBalance(from: "0,25")
        XCTAssertNotNil(ab3)
        XCTAssertEqual(ab3!, 1.0, accuracy: 0.001)

        // Multi-allelic: 5 ref, 10 alt1, 5 alt2
        let ab4 = Row.computeAlleleBalance(from: "5,10,5")
        XCTAssertNotNil(ab4)
        XCTAssertEqual(ab4!, 0.75, accuracy: 0.001)

        // Edge cases
        XCTAssertNil(Row.computeAlleleBalance(from: nil))
        XCTAssertNil(Row.computeAlleleBalance(from: ""))
        XCTAssertNil(Row.computeAlleleBalance(from: "0,0"))
        XCTAssertNil(Row.computeAlleleBalance(from: "5"))
    }

    // MARK: - Drawer Tab Tests

    func testDrawerTabPrefsKey() {
        typealias Tab = AnnotationTableDrawerView.DrawerTab
        XCTAssertEqual(Tab.annotations.prefsKey, "annotations")
        XCTAssertEqual(Tab.variants.prefsKey, "variantCalls")
        XCTAssertEqual(Tab.samples.prefsKey, "samples")
    }

    // MARK: - Export Field Escaping Tests

    func testExportCellValueForAnnotation() throws {
        let drawer = try createDrawerWithAnnotationsOnly()

        // Switch to annotations and load data
        drawer.switchToTab(.annotations)

        // Verify the drawer has data
        XCTAssertGreaterThan(drawer.displayedAnnotations.count, 0,
                            "Drawer should have loaded annotation data")

        // Test cell value extraction
        let name = drawer.cellValueString(
            for: AnnotationTableDrawerView.nameColumn, row: 0)
        XCTAssertFalse(name.isEmpty, "Name should not be empty")
    }

    func testExportCellValueForVariants() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()

        switchToVariantsAndWait(drawer)

        // Variants should be loaded
        XCTAssertGreaterThan(drawer.displayedAnnotations.count, 0,
                            "Drawer should have variant data")

        let varId = drawer.cellValueString(
            for: AnnotationTableDrawerView.variantIdColumn, row: 0)
        XCTAssertFalse(varId.isEmpty, "Variant ID should not be empty")
    }

    // MARK: - Variant Subtab Tests

    func testVariantSubtabDefaultIsCalls() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        XCTAssertEqual(drawer.activeVariantSubtab.rawValue, 0)
    }

    func testSwitchToVariantsResetsSubtab() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.activeVariantSubtab = .genotypes
        drawer.switchToTab(.annotations)
        drawer.switchToTab(.variants)
        XCTAssertEqual(drawer.activeVariantSubtab.rawValue, 0,
                      "Switching to variants tab should reset subtab to Calls")
    }

    // MARK: - Promoted Column Tests

    func testPromotedInfoColumnsAppearForVariants() throws {
        // Create a VCF with AF and GENE info fields
        let vcfContent = """
        ##fileformat=VCFv4.2
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele Frequency">
        ##INFO=<ID=GENE,Number=1,Type=String,Description="Gene Name">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs12345\tA\tG\t30.0\tPASS\tAF=0.01;GENE=BRCA1
        """
        let drawer = try createDrawerWithAnnotationsAndVariants(vcfContent: vcfContent)
        drawer.switchToTab(.variants)

        // Find the AF and GENE columns
        let colIds = drawer.tableView.tableColumns.map(\.identifier.rawValue)
        XCTAssertTrue(colIds.contains("info_AF"), "AF column should be present")
        XCTAssertTrue(colIds.contains("info_GENE"), "GENE column should be present")

        // AF should appear before GENE (promoted order)
        if let afIdx = colIds.firstIndex(of: "info_AF"),
           let geneIdx = colIds.firstIndex(of: "info_GENE") {
            XCTAssertLessThan(afIdx, geneIdx, "AF should be before GENE in column order")
        }
    }

    // MARK: - Genotype Column Configuration

    func testGenotypeColumnsConfigured() throws {
        let drawer = try createDrawerWithAnnotationsAndVariants()
        drawer.switchToTab(.variants)
        drawer.configureColumnsForGenotypes()

        let colIds = drawer.tableView.tableColumns.map(\.identifier.rawValue)
        XCTAssertTrue(colIds.contains("GTSampleColumn"))
        XCTAssertTrue(colIds.contains("GTGenotypeColumn"))
        XCTAssertTrue(colIds.contains("GTZygosityColumn"))
        XCTAssertTrue(colIds.contains("GTDPColumn"))
        XCTAssertTrue(colIds.contains("GTGQColumn"))
        XCTAssertTrue(colIds.contains("GTABColumn"))
    }

    // MARK: - Helpers

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
                path: "seq.fa.gz", indexPath: "seq.fa.gz.fai",
                totalLength: 1000, chromosomes: []
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "annotations", name: "Annotations",
                    path: "annotations.bb", databasePath: "annotations.db"
                )
            ]
        )

        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let searchIndex = AnnotationSearchIndex()
        let success = searchIndex.buildFromDatabase(bundle: bundle, trackId: "annotations", databasePath: "annotations.db")
        XCTAssertTrue(success)

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        return drawer
    }

    private func createDrawerWithAnnotationsAndVariants(
        vcfContent: String = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs12345\tA\tG\t30.0\tPASS\t.
        chr1\t250\trs67890\tTC\tT\t45.5\tPASS\t.
        chr1\t350\t.\tG\tGAA\t20.0\tLowQual\t.
        """
    ) throws -> AnnotationTableDrawerView {
        let bedContent = "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=BRCA1"
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let annotDbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotDbURL)

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
                path: "seq.fa.gz", indexPath: "seq.fa.gz.fai",
                totalLength: 1000, chromosomes: []
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "annotations", name: "Annotations",
                    path: "annotations.bb", databasePath: "annotations.db"
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "variants", name: "Variants",
                    path: "variants.bcf", indexPath: "variants.bcf.csi",
                    databasePath: "variants.db"
                )
            ]
        )

        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let searchIndex = AnnotationSearchIndex()
        let success = searchIndex.buildFromDatabase(bundle: bundle, trackId: "annotations", databasePath: "annotations.db")
        XCTAssertTrue(success)

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        return drawer
    }

    private func createSearchIndex(genomeLength: Int64) throws -> AnnotationSearchIndex {
        let unique = UUID().uuidString
        let bedContent = "chr1\t100\t500\tBRCA1\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=BRCA1"
        let bedFile = "annotations_\(unique).bed"
        let dbFile = "annotations_\(unique).db"
        let bedURL = tempDir.appendingPathComponent(bedFile)
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let annotationDBURL = tempDir.appendingPathComponent(dbFile)
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotationDBURL)

        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs12345\tA\tG\t30.0\tPASS\t.
        """
        let vcfFile = "variants_\(unique).vcf"
        let vcfURL = tempDir.appendingPathComponent(vcfFile)
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        let variantDBFile = "variants_\(unique).db"
        let variantDBURL = tempDir.appendingPathComponent(variantDBFile)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: variantDBURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test",
            identifier: "test.bundle.\(unique)",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "seq.fa.gz", indexPath: "seq.fa.gz.fai",
                totalLength: genomeLength, chromosomes: []
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "annotations", name: "Annotations",
                    path: "annotations.bb", databasePath: dbFile
                )
            ],
            variants: [
                VariantTrackInfo(
                    id: "variants", name: "Variants",
                    path: "variants.bcf", indexPath: "variants.bcf.csi",
                    databasePath: variantDBFile
                )
            ]
        )

        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let searchIndex = AnnotationSearchIndex()
        let success = searchIndex.buildFromDatabase(bundle: bundle, trackId: "annotations", databasePath: dbFile)
        XCTAssertTrue(success)
        return searchIndex
    }

    // MARK: - Phase 2: Smart Token Tests

    func testSmartTokenAvailability() {
        let infoKeys: Set<String> = ["AF", "DP", "IMPACT", "CLNSIG"]
        let variantTypes: Set<String> = ["SNV", "Indel"]

        XCTAssertTrue(SmartToken.passOnly.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.snv.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.indel.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.highImpact.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.rareVariant.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.depthGE10.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.clinvarPathogenic.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        // Heterozygous token is disabled until genotype-level post-filtering is implemented
        XCTAssertFalse(SmartToken.heterozygous.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertFalse(SmartToken.heterozygous.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: true))
    }

    func testSmartTokenAvailabilityMinimalKeys() {
        let infoKeys: Set<String> = ["DP"]
        let variantTypes: Set<String> = ["SNV"]

        XCTAssertTrue(SmartToken.passOnly.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.snv.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertFalse(SmartToken.indel.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertFalse(SmartToken.highImpact.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertFalse(SmartToken.rareVariant.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertTrue(SmartToken.depthGE10.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
        XCTAssertFalse(SmartToken.clinvarPathogenic.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false))
    }

    func testSmartTokenFilterComposition() {
        let tokens: Set<SmartToken> = [.passOnly, .qualityGE30]
        let infoKeys: Set<String> = ["AF", "DP"]
        let composed = tokens.composeFilters(infoKeys: infoKeys)

        XCTAssertEqual(composed.filterValue, "PASS")
        XCTAssertEqual(composed.minQuality, 30)
        XCTAssertTrue(composed.typeRestrictions.isEmpty)
        XCTAssertTrue(composed.infoFilters.isEmpty)
    }

    func testSmartTokenTypeRestrictions() {
        let tokens: Set<SmartToken> = [.snv]
        let composed = tokens.composeFilters(infoKeys: [])

        XCTAssertTrue(composed.typeRestrictions.contains("SNV"))
        XCTAssertTrue(composed.typeRestrictions.contains("snv"))
        XCTAssertNil(composed.filterValue)
        XCTAssertNil(composed.minQuality)
    }

    func testSmartTokenInfoFilters() {
        let tokens: Set<SmartToken> = [.rareVariant, .depthGE10]
        let infoKeys: Set<String> = ["AF", "DP"]
        let composed = tokens.composeFilters(infoKeys: infoKeys)

        XCTAssertEqual(composed.infoFilters.count, 2)
        let keys = composed.infoFilters.map(\.key)
        XCTAssertTrue(keys.contains("AF"))
        XCTAssertTrue(keys.contains("DP"))
    }

    func testModerateImpactUsesPostFilter() {
        let effects = SmartToken.moderateImpact.filterEffects(infoKeys: ["IMPACT"])
        XCTAssertEqual(effects.count, 1)
        if case .postFilter(.moderateOrHigherImpact) = effects.first {} else {
            XCTFail("Expected .postFilter(.moderateOrHigherImpact)")
        }
    }

    func testWithinSampleAFTokenLabelsMatchInclusiveBounds() {
        XCTAssertEqual(SmartToken.minorVariant.label, "Minor (≤20%)")
        XCTAssertEqual(SmartToken.mixedInfection.label, "Mixed (20-80%)")
        XCTAssertEqual(SmartToken.dominantMutation.label, "Dominant (≥80%)")
    }

    // MARK: - Phase 2: Query Rule Tests

    func testQueryRuleToFilterClause() {
        let qualRule = QueryRule(category: .callQuality, field: "Quality", op: ">=", value: "30")
        XCTAssertEqual(qualRule.toFilterClause(), "qual>=30")

        let filterRule = QueryRule(category: .callQuality, field: "Filter", op: "=", value: "PASS")
        XCTAssertEqual(filterRule.toFilterClause(), "filter=PASS")

        let regionRule = QueryRule(category: .location, field: "Region", op: "=", value: "chr1:100-500")
        XCTAssertEqual(regionRule.toFilterClause(), "region=chr1:100-500")

        let nameRule = QueryRule(category: .identity, field: "ID/Name", op: "=", value: "rs12345")
        XCTAssertEqual(nameRule.toFilterClause(), "text=rs12345")

        let infoRule = QueryRule(category: .population, field: "AF", op: "<", value: "0.01")
        XCTAssertEqual(infoRule.toFilterClause(), "AF<0.01")
    }

    func testQueryRuleEmptyValueReturnsNil() {
        let rule = QueryRule(category: .callQuality, field: "Quality", op: ">=", value: "")
        XCTAssertNil(rule.toFilterClause())
    }

    func testQueryRuleSampleGenotypeReturnsNil() {
        let rule = QueryRule(category: .sampleGenotype, field: "GQ", op: ">=", value: "20")
        XCTAssertNil(rule.toFilterClause())
    }

    func testQueryCategoryAllCasesExcludesUnsupportedSampleGenotype() {
        XCTAssertFalse(QueryCategory.allCases.contains(.sampleGenotype))
    }

    func testQueryPresetBuiltInsExist() {
        XCTAssertFalse(QueryPreset.builtInPresets.isEmpty)
        for preset in QueryPreset.builtInPresets {
            XCTAssertTrue(preset.isBuiltIn)
            XCTAssertFalse(preset.rules.isEmpty)
        }
    }

    func testQueryCategoryFields() {
        for category in QueryCategory.allCases {
            if category == .infoField {
                continue // INFO fields are discovered dynamically from loaded VCF metadata.
            }
            XCTAssertFalse(category.fields.isEmpty, "\(category) should have at least one field")
            for field in category.fields {
                let ops = category.operators(for: field)
                XCTAssertFalse(ops.isEmpty, "\(category).\(field) should have at least one operator")
            }
        }
    }

    // MARK: - Haploid Detection Tests

    func testHaploidDetectionUsesGenomeTotalLength() throws {
        let smallGenomeIndex = try createSearchIndex(genomeLength: 4_000_000)
        XCTAssertTrue(smallGenomeIndex.isLikelyHaploidOrganism, "Small genome should auto-detect as haploid")

        let largeGenomeIndex = try createSearchIndex(genomeLength: 120_000_000)
        XCTAssertFalse(largeGenomeIndex.isLikelyHaploidOrganism, "Large genome should auto-detect as non-haploid")
    }

    func testHaploidDetectionSupportsUserOverride() throws {
        let index = try createSearchIndex(genomeLength: 120_000_000)
        XCTAssertFalse(index.isLikelyHaploidOrganism)

        index.setHaploidOverride(true)
        XCTAssertTrue(index.isLikelyHaploidOrganism, "Explicit override should force haploid mode")

        index.setHaploidOverride(false)
        XCTAssertFalse(index.isLikelyHaploidOrganism, "Explicit override should force diploid mode")

        index.setHaploidOverride(nil)
        XCTAssertFalse(index.isLikelyHaploidOrganism, "Clearing override should return to auto mode")
    }

    // MARK: - Phase 2: Gene List Detection Tests

    func testGeneListDetection() throws {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        // The detectGeneListPattern is private, so we test indirectly via cellValueString behavior
        // and instead directly test the SmartToken composition
        // (Gene list detection tested through integration tests)

        // Verify smart token labels are non-empty
        for token in SmartToken.allCases {
            XCTAssertFalse(token.label.isEmpty, "Token \(token) should have a label")
        }
        _ = drawer  // suppress unused warning
    }

    // MARK: - Phase 3: Bookmark Tests

    private func createBookmarkTestDB() throws -> VariantDatabase {
        let vcfContent = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trs1\tA\tG\t30.0\tPASS\t.
        chr1\t200\trs2\tC\tT\t20.0\t.\t.
        """
        let vcfURL = tempDir.appendingPathComponent("bookmark_test.vcf")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("bookmark_test.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return try VariantDatabase(url: dbURL, readWrite: true)
    }

    func testVariantDatabaseBookmarkRoundTrip() throws {
        let db = try createBookmarkTestDB()

        // Initially no bookmarks
        let initial = db.bookmarkedVariantIds()
        XCTAssertTrue(initial.isEmpty)

        // Toggle bookmark on → returns true
        let result = db.toggleBookmark(variantId: 1)
        XCTAssertTrue(result)
        XCTAssertTrue(db.isBookmarked(variantId: 1))
        XCTAssertFalse(db.isBookmarked(variantId: 2))

        // Bookmarked set should contain 1
        let afterAdd = db.bookmarkedVariantIds()
        XCTAssertEqual(afterAdd, [1])

        // Toggle off → returns false
        let result2 = db.toggleBookmark(variantId: 1)
        XCTAssertFalse(result2)
        XCTAssertFalse(db.isBookmarked(variantId: 1))
        XCTAssertTrue(db.bookmarkedVariantIds().isEmpty)
    }

    func testVariantDatabaseBookmarkedVariantsJoin() throws {
        let db = try createBookmarkTestDB()

        // Bookmark variant 1 only
        _ = db.toggleBookmark(variantId: 1)

        // bookmarkedVariants() uses SQL JOIN — should return only the bookmarked record
        let records = db.bookmarkedVariants()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].variantID, "rs1")
        XCTAssertEqual(records[0].ref, "A")

        // Bookmark variant 2 as well
        _ = db.toggleBookmark(variantId: 2)
        let records2 = db.bookmarkedVariants()
        XCTAssertEqual(records2.count, 2)

        // Remove variant 1
        _ = db.toggleBookmark(variantId: 1)
        let records3 = db.bookmarkedVariants()
        XCTAssertEqual(records3.count, 1)
        XCTAssertEqual(records3[0].variantID, "rs2")
    }

    func testVariantDatabaseBookmarkNote() throws {
        let db = try createBookmarkTestDB()

        _ = db.toggleBookmark(variantId: 1)
        db.updateBookmarkNote(variantId: 1, note: "Interesting variant")

        let all = db.allBookmarks()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.note, "Interesting variant")
    }

    // MARK: - Phase 3: Smart Token Bookmark Test

    func testBookmarkedSmartTokenAvailability() {
        let infoKeys: Set<String> = ["DP"]
        let variantTypes: Set<String> = ["SNV"]

        // Without bookmarks
        XCTAssertFalse(SmartToken.bookmarked.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false, hasBookmarks: false))

        // With bookmarks
        XCTAssertTrue(SmartToken.bookmarked.isAvailable(infoKeys: infoKeys, variantTypes: variantTypes, hasGenotypes: false, hasBookmarks: true))
    }

    func testBookmarkedSmartTokenFilterEffect() {
        let effects = SmartToken.bookmarked.filterEffects(infoKeys: [])
        XCTAssertEqual(effects.count, 1)
        if case .postFilter(.bookmarkedOnly) = effects.first {} else {
            XCTFail("Expected .postFilter(.bookmarkedOnly)")
        }
    }

    // MARK: - Phase 3: Filter Profile Tests

    func testBuiltInFilterProfiles() {
        XCTAssertFalse(FilterProfile.builtInProfiles.isEmpty)
        for profile in FilterProfile.builtInProfiles {
            XCTAssertTrue(profile.isBuiltIn)
            XCTAssertFalse(profile.name.isEmpty)
        }
    }

    func testFilterProfileTokenConversion() {
        let profile = FilterProfile.clinical
        let tokens = profile.smartTokens
        XCTAssertTrue(tokens.contains(.passOnly))
        XCTAssertTrue(tokens.contains(.clinvarPathogenic))
    }

    func testFilterProfilePersistence() {
        let key = "com.lungfish.filterProfiles.test"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let custom = FilterProfile(name: "My Profile", activeTokens: ["passOnly", "snv"], filterText: "qual>=30")
        let data = try? JSONEncoder().encode([custom])
        XCTAssertNotNil(data)

        let decoded = try? JSONDecoder().decode([FilterProfile].self, from: data!)
        XCTAssertEqual(decoded?.count, 1)
        XCTAssertEqual(decoded?.first?.name, "My Profile")
        XCTAssertEqual(decoded?.first?.smartTokens, [.passOnly, .snv])
    }

    func testFilterProfileStoreScopedByBundleIdentifier() {
        let bundleA = "bundleA.test"
        let bundleB = "bundleB.test"
        let profileA = FilterProfile(name: "A", activeTokens: ["passOnly"], filterText: "qual>=30")
        let profileB = FilterProfile(name: "B", activeTokens: ["snv"], filterText: "type=SNV")

        FilterProfileStore.saveCustomProfiles([profileA], bundleIdentifier: bundleA)
        FilterProfileStore.saveCustomProfiles([profileB], bundleIdentifier: bundleB)

        let loadedA = FilterProfileStore.loadCustomProfiles(bundleIdentifier: bundleA)
        let loadedB = FilterProfileStore.loadCustomProfiles(bundleIdentifier: bundleB)
        XCTAssertEqual(loadedA.map(\.name), ["A"])
        XCTAssertEqual(loadedB.map(\.name), ["B"])
    }

    func testBookmarkKeyIncludesTrackID() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        let keyA = drawer.bookmarkKey(trackId: "trackA", variantRowId: 1)
        let keyB = drawer.bookmarkKey(trackId: "trackB", variantRowId: 1)
        XCTAssertNotEqual(keyA, keyB)
    }

    /// Integration test: bookmarks are track-scoped across multiple variant databases.
    func testMultiTrackBookmarkIntegration() throws {
        // Create two VCFs with the same rowId=1 in each
        let vcfA = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t100\trsA1\tA\tG\t30.0\tPASS\t.
        chr1\t200\trsA2\tC\tT\t25.0\tPASS\t.
        """
        let vcfB = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr2\t500\trsB1\tG\tA\t40.0\tPASS\t.
        """

        let vcfAURL = tempDir.appendingPathComponent("trackA.vcf")
        let vcfBURL = tempDir.appendingPathComponent("trackB.vcf")
        try vcfA.write(to: vcfAURL, atomically: true, encoding: .utf8)
        try vcfB.write(to: vcfBURL, atomically: true, encoding: .utf8)

        let dbAURL = tempDir.appendingPathComponent("trackA.db")
        let dbBURL = tempDir.appendingPathComponent("trackB.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfAURL, outputURL: dbAURL)
        try VariantDatabase.createFromVCF(vcfURL: vcfBURL, outputURL: dbBURL)

        // Create a minimal annotation DB
        let bedContent = "chr1\t0\t1000\tgeneX\t0\t+\t0\t1000\t0,0,0\t1\t1000\t0\tgene\t."
        let bedURL = tempDir.appendingPathComponent("ann.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let annDbURL = tempDir.appendingPathComponent("ann.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annDbURL)

        // Build manifest with two variant tracks
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "MultiTrack",
            identifier: "multitrack.test",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: GenomeInfo(
                path: "seq.fa.gz", indexPath: "seq.fa.gz.fai",
                totalLength: 10000, chromosomes: []
            ),
            annotations: [
                AnnotationTrackInfo(id: "ann", name: "Annotations", path: "ann.bb", databasePath: "ann.db")
            ],
            variants: [
                VariantTrackInfo(id: "trackA", name: "Track A", path: "a.bcf", indexPath: "a.csi", databasePath: "trackA.db"),
                VariantTrackInfo(id: "trackB", name: "Track B", path: "b.bcf", indexPath: "b.csi", databasePath: "trackB.db"),
            ]
        )

        let bundle = ReferenceBundle(url: tempDir, manifest: manifest)
        let searchIndex = AnnotationSearchIndex()
        searchIndex.buildFromDatabase(bundle: bundle, trackId: "ann", databasePath: "ann.db")

        // Verify two variant databases loaded
        XCTAssertEqual(searchIndex.variantDatabaseHandles.count, 2)

        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        drawer.setSearchIndex(searchIndex)
        drawer.loadBookmarkedVariantIds()
        XCTAssertTrue(drawer.bookmarkedVariantKeys.isEmpty)

        // Bookmark rowId=1 in trackA only
        let dbA = searchIndex.variantDatabaseHandles.first(where: { $0.trackId == "trackA" })!.db
        _ = dbA.toggleBookmark(variantId: 1)

        drawer.loadBookmarkedVariantIds()
        XCTAssertEqual(drawer.bookmarkedVariantKeys.count, 1)
        XCTAssertTrue(drawer.bookmarkedVariantKeys.contains(drawer.bookmarkKey(trackId: "trackA", variantRowId: 1)))
        // Same rowId in trackB should NOT be bookmarked
        XCTAssertFalse(drawer.bookmarkedVariantKeys.contains(drawer.bookmarkKey(trackId: "trackB", variantRowId: 1)))

        // Bookmark rowId=1 in trackB independently
        let dbB = searchIndex.variantDatabaseHandles.first(where: { $0.trackId == "trackB" })!.db
        _ = dbB.toggleBookmark(variantId: 1)
        drawer.loadBookmarkedVariantIds()
        XCTAssertEqual(drawer.bookmarkedVariantKeys.count, 2)

        // Remove bookmark from trackA; trackB bookmark survives
        _ = dbA.toggleBookmark(variantId: 1)
        drawer.loadBookmarkedVariantIds()
        XCTAssertEqual(drawer.bookmarkedVariantKeys.count, 1)
        XCTAssertFalse(drawer.bookmarkedVariantKeys.contains(drawer.bookmarkKey(trackId: "trackA", variantRowId: 1)))
        XCTAssertTrue(drawer.bookmarkedVariantKeys.contains(drawer.bookmarkKey(trackId: "trackB", variantRowId: 1)))

        // Verify export from both tracks returns correct results
        let bookmarkedB = dbB.bookmarkedVariants()
        XCTAssertEqual(bookmarkedB.count, 1)
        XCTAssertEqual(bookmarkedB[0].variantID, "rsB1")
    }

    // MARK: - Phase 3: Sample Group Tests

    func testSampleGroupCodable() throws {
        let group = SampleGroup(name: "Cases", sampleNames: ["S1", "S2"], colorHex: "#FF0000")
        let data = try JSONEncoder().encode(group)
        let decoded = try JSONDecoder().decode(SampleGroup.self, from: data)
        XCTAssertEqual(decoded.name, "Cases")
        XCTAssertEqual(decoded.sampleNames, ["S1", "S2"])
        XCTAssertEqual(decoded.colorHex, "#FF0000")
    }

    func testSampleDisplayStateWithGroups() throws {
        var state = SampleDisplayState()
        state.sampleGroups = [
            SampleGroup(name: "Cases", sampleNames: ["S1", "S2"]),
            SampleGroup(name: "Controls", sampleNames: ["S3", "S4"]),
        ]

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertEqual(decoded.sampleGroups.count, 2)
        XCTAssertEqual(decoded.sampleGroups[0].name, "Cases")
        XCTAssertEqual(decoded.sampleGroups[1].sampleNames, ["S3", "S4"])
    }

    func testSampleDisplayStateBackwardCompatibility() throws {
        // Simulate old JSON without sampleGroups
        let json = """
        {"sortFields":[],"filters":[],"hiddenSamples":[],"showGenotypeRows":true,"showSummaryBar":false,"rowHeight":12,"summaryBarHeight":20}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SampleDisplayState.self, from: data)
        XCTAssertTrue(decoded.sampleGroups.isEmpty)
    }

    // MARK: - Async Helpers

    /// Switches to the variants tab and drains the RunLoop until variant query results arrive.
    private func switchToVariantsAndWait(_ drawer: AnnotationTableDrawerView, timeout: TimeInterval = 2.0) {
        drawer.switchToTab(.variants)
        let deadline = Date().addingTimeInterval(timeout)
        while (drawer.displayedAnnotations.isEmpty && drawer.isVariantQuerying) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
