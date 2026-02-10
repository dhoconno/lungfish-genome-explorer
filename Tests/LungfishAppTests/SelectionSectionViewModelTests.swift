// SelectionSectionViewModelTests.swift - Tests for Inspector qualifier enrichment
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class SelectionSectionViewModelTests: XCTestCase {

    // MARK: - extractEnrichment from qualifiers["extra"]

    func testExtractEnrichmentFromExtraQualifiers() {
        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            chromosome: "chr17",
            intervals: [AnnotationInterval(start: 1000, end: 5000)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("gene=BRCA1;product=breast%20cancer%20type%201;gene_biotype=protein_coding;description=BRCA1%20DNA%20repair%20associated")
            ]
        )

        vm.select(annotation: annotation)

        // Should have extracted all non-excluded qualifiers
        let keys = vm.qualifierPairs.map(\.key)
        XCTAssertTrue(keys.contains("Gene"), "Should extract 'gene' as 'Gene'")
        XCTAssertTrue(keys.contains("Product"), "Should extract 'product' as 'Product'")
        XCTAssertTrue(keys.contains("Biotype"), "Should extract 'gene_biotype' as 'Biotype'")
        XCTAssertTrue(keys.contains("Description"), "Should extract 'description' as 'Description'")

        // Check values are URL-decoded
        let product = vm.qualifierPairs.first(where: { $0.key == "Product" })?.value
        XCTAssertEqual(product, "breast cancer type 1")

        let desc = vm.qualifierPairs.first(where: { $0.key == "Description" })?.value
        XCTAssertEqual(desc, "BRCA1 DNA repair associated")
    }

    func testExtractEnrichmentParsesDbxrefLinks() {
        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "gag",
            chromosome: "NC_001802.1",
            intervals: [AnnotationInterval(start: 336, end: 1838)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("gene=gag;db_xref=GeneID%3A155030,UniProt%3AP12493")
            ]
        )

        vm.select(annotation: annotation)

        XCTAssertEqual(vm.dbxrefLinks.count, 2)

        // GeneID link
        let geneLink = vm.dbxrefLinks.first(where: { $0.database == "GeneID" })
        XCTAssertNotNil(geneLink)
        XCTAssertEqual(geneLink?.id, "155030")
        XCTAssertNotNil(geneLink?.url)
        XCTAssertTrue(geneLink!.url!.absoluteString.contains("ncbi.nlm.nih.gov/gene/155030"))

        // UniProt link
        let uniprotLink = vm.dbxrefLinks.first(where: { $0.database == "UniProt" })
        XCTAssertNotNil(uniprotLink)
        XCTAssertEqual(uniprotLink?.id, "P12493")
        XCTAssertNotNil(uniprotLink?.url)
        XCTAssertTrue(uniprotLink!.url!.absoluteString.contains("uniprot.org/uniprot/P12493"))
    }

    func testExtractEnrichmentExcludesInternalQualifiers() {
        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [
                "score": AnnotationQualifier("100"),
                "extra": AnnotationQualifier("gene=TEST;_lf_raw_feature_type=primer_bind")
            ]
        )

        vm.select(annotation: annotation)

        let keys = vm.qualifierPairs.map(\.key)
        XCTAssertFalse(keys.contains("score"), "'score' should be excluded")
        XCTAssertFalse(keys.contains("extra"), "'extra' should be excluded")
        XCTAssertFalse(keys.contains("_lf_raw_feature_type"), "Internal marker should be excluded")
        XCTAssertTrue(keys.contains("Gene"), "'gene' should be included")
    }

    func testExtractEnrichmentFromTabSeparatedExtra() {
        let vm = SelectionSectionViewModel()

        // Format used by GFF3: "type\tkey=val;key=val"
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "LOC123",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("gene\tgene=LOC123;description=hypothetical%20protein")
            ]
        )

        vm.select(annotation: annotation)

        let keys = vm.qualifierPairs.map(\.key)
        XCTAssertTrue(keys.contains("Gene"))
        XCTAssertTrue(keys.contains("Description"))
    }

    // MARK: - extractEnrichment from SQLite database

    func testExtractEnrichmentFromDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bedContent = "chr1\t100\t500\tgeneA\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=BRCA1;product=breast%20cancer%20type%201;db_xref=GeneID%3A672"
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let db = try AnnotationDatabase(url: dbURL)

        let vm = SelectionSectionViewModel()
        vm.annotationDatabase = db

        // Annotation WITHOUT qualifiers["extra"] — enrichment should come from database
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "geneA",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [:]
        )

        vm.select(annotation: annotation)

        let keys = vm.qualifierPairs.map(\.key)
        XCTAssertTrue(keys.contains("Gene"), "Should get 'gene' from database")
        XCTAssertTrue(keys.contains("Product"), "Should get 'product' from database")

        XCTAssertEqual(vm.dbxrefLinks.count, 1)
        XCTAssertEqual(vm.dbxrefLinks.first?.database, "GeneID")
        XCTAssertEqual(vm.dbxrefLinks.first?.id, "672")
    }

    func testExtractEnrichmentMergesExtraAndDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector_merge_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Database has product and db_xref
        let bedContent = "chr1\t100\t500\tgeneA\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tproduct=some%20protein;db_xref=GeneID%3A12345"
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let db = try AnnotationDatabase(url: dbURL)

        let vm = SelectionSectionViewModel()
        vm.annotationDatabase = db

        // Annotation has gene in extra but NOT product
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "geneA",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("gene=BRCA1")
            ]
        )

        vm.select(annotation: annotation)

        let keys = vm.qualifierPairs.map(\.key)
        // gene comes from extra
        XCTAssertTrue(keys.contains("Gene"))
        let geneValue = vm.qualifierPairs.first(where: { $0.key == "Gene" })?.value
        XCTAssertEqual(geneValue, "BRCA1", "Gene value should come from annotation (extra)")

        // product comes from database (not in extra)
        XCTAssertTrue(keys.contains("Product"), "Product should be supplemented from database")
    }

    func testSettingDatabaseAfterSelectionRefreshesEnrichment() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector_late_db_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bedContent = "chr1\t100\t500\tgeneA\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tgene\tgene=BRCA1;product=some%20protein"
        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let db = try AnnotationDatabase(url: dbURL)

        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "geneA",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [:]
        )

        // Select first with no DB: no enrichment.
        vm.select(annotation: annotation)
        XCTAssertTrue(vm.qualifierPairs.isEmpty)

        // Wire DB afterward: enrichment should refresh without re-selection.
        vm.annotationDatabase = db

        let keys = vm.qualifierPairs.map(\.key)
        XCTAssertTrue(keys.contains("Gene"))
        XCTAssertTrue(keys.contains("Product"))
    }

    // MARK: - makeDbxrefURL

    func testMakeDbxrefURLForKnownDatabases() {
        let geneURL = SelectionSectionViewModel.makeDbxrefURL(database: "GeneID", id: "12345")
        XCTAssertNotNil(geneURL)
        XCTAssertEqual(geneURL?.absoluteString, "https://www.ncbi.nlm.nih.gov/gene/12345")

        let uniprotURL = SelectionSectionViewModel.makeDbxrefURL(database: "UniProt", id: "P12345")
        XCTAssertNotNil(uniprotURL)
        XCTAssertEqual(uniprotURL?.absoluteString, "https://www.uniprot.org/uniprot/P12345")

        let taxonURL = SelectionSectionViewModel.makeDbxrefURL(database: "taxon", id: "9606")
        XCTAssertNotNil(taxonURL)
        XCTAssertTrue(taxonURL!.absoluteString.contains("9606"))

        let interproURL = SelectionSectionViewModel.makeDbxrefURL(database: "InterPro", id: "IPR000001")
        XCTAssertNotNil(interproURL)
        XCTAssertTrue(interproURL!.absoluteString.contains("IPR000001"))

        let pdbURL = SelectionSectionViewModel.makeDbxrefURL(database: "PDB", id: "1ABC")
        XCTAssertNotNil(pdbURL)
        XCTAssertTrue(pdbURL!.absoluteString.contains("1ABC"))

        let goURL = SelectionSectionViewModel.makeDbxrefURL(database: "GO", id: "0003674")
        XCTAssertNotNil(goURL)
        XCTAssertTrue(goURL!.absoluteString.contains("GO:0003674"))

        let hgncURL = SelectionSectionViewModel.makeDbxrefURL(database: "HGNC", id: "1100")
        XCTAssertNotNil(hgncURL)
        XCTAssertTrue(hgncURL!.absoluteString.contains("HGNC:1100"))

        let omimURL = SelectionSectionViewModel.makeDbxrefURL(database: "OMIM", id: "113705")
        XCTAssertNotNil(omimURL)
        XCTAssertTrue(omimURL!.absoluteString.contains("113705"))
    }

    func testMakeDbxrefURLReturnsNilForUnknownDatabase() {
        let url = SelectionSectionViewModel.makeDbxrefURL(database: "UnknownDB", id: "123")
        XCTAssertNil(url, "Unknown database should return nil URL")
    }

    // MARK: - displayKeyName

    func testDisplayKeyNames() {
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("gene"), "Gene")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("product"), "Product")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("description"), "Description")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("gene_biotype"), "Biotype")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("protein_id"), "Protein ID")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("transcript_id"), "Transcript ID")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("note"), "Note")
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("codon_start"), "Codon Start")
        // Unknown keys pass through unchanged
        XCTAssertEqual(SelectionSectionViewModel.displayKeyName("some_custom_key"), "some_custom_key")
    }

    // MARK: - Deselection clears enrichment

    func testDeselectionClearsEnrichment() {
        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("gene=TEST;db_xref=GeneID%3A12345")
            ]
        )

        vm.select(annotation: annotation)
        XCTAssertFalse(vm.qualifierPairs.isEmpty)
        XCTAssertFalse(vm.dbxrefLinks.isEmpty)

        vm.select(annotation: nil)
        XCTAssertTrue(vm.qualifierPairs.isEmpty, "Qualifier pairs should be cleared on deselection")
        XCTAssertTrue(vm.dbxrefLinks.isEmpty, "Dbxref links should be cleared on deselection")
    }

    // MARK: - Translation truncation

    func testLongTranslationIsTruncated() {
        let vm = SelectionSectionViewModel()

        let longTranslation = String(repeating: "M", count: 200)
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "testCDS",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 700)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("translation=\(longTranslation)")
            ]
        )

        vm.select(annotation: annotation)

        let translationPair = vm.qualifierPairs.first(where: { $0.key == "Translation" })
        XCTAssertNotNil(translationPair)
        XCTAssertTrue(translationPair!.value.hasSuffix("..."), "Long translation should be truncated")
        XCTAssertLessThanOrEqual(translationPair!.value.count, 84, "Truncated to ~80 chars + '...'")

        // fullTranslation should contain the complete, un-truncated sequence
        XCTAssertNotNil(vm.fullTranslation, "fullTranslation should be populated")
        XCTAssertEqual(vm.fullTranslation, longTranslation, "fullTranslation should store the complete sequence")
    }

    func testFullTranslationClearedOnDeselection() {
        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "testCDS",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 700)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("translation=MFVLK")
            ]
        )
        vm.select(annotation: annotation)
        XCTAssertNotNil(vm.fullTranslation)

        vm.select(annotation: nil)
        XCTAssertNil(vm.fullTranslation, "fullTranslation should be nil after deselection")
        XCTAssertFalse(vm.isTranslationVisible, "isTranslationVisible should reset on deselection")
    }

    func testShortTranslationStoredInFullTranslation() {
        let vm = SelectionSectionViewModel()

        let shortTranslation = "MFVLK"
        let annotation = SequenceAnnotation(
            type: .cds,
            name: "testCDS",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 700)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("translation=\(shortTranslation)")
            ]
        )
        vm.select(annotation: annotation)

        // Short translations should appear un-truncated in qualifier pairs
        let translationPair = vm.qualifierPairs.first(where: { $0.key == "Translation" })
        XCTAssertNotNil(translationPair)
        XCTAssertEqual(translationPair!.value, shortTranslation)

        // And also be stored in fullTranslation
        XCTAssertEqual(vm.fullTranslation, shortTranslation)
    }

    func testTranslationVisibilityResetsWhenSelectingDifferentAnnotation() {
        let vm = SelectionSectionViewModel()

        let annotationA = SequenceAnnotation(
            type: .cds,
            name: "cdsA",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 160)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("translation=MAAA")
            ]
        )

        let annotationB = SequenceAnnotation(
            type: .cds,
            name: "cdsB",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 200, end: 260)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("translation=MBBB")
            ]
        )

        vm.select(annotation: annotationA)
        vm.isTranslationVisible = true

        vm.select(annotation: annotationB)
        XCTAssertFalse(vm.isTranslationVisible, "isTranslationVisible should reset when switching annotations")
    }

    func testDeleteClearsSelectionState() {
        let vm = SelectionSectionViewModel()

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "toDelete",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 160)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("gene=ABC1;translation=MAAA")
            ]
        )

        vm.select(annotation: annotation)
        vm.isTranslationVisible = true
        XCTAssertFalse(vm.qualifierPairs.isEmpty)
        XCTAssertNotNil(vm.fullTranslation)

        vm.deleteAnnotation()

        XCTAssertNil(vm.selectedAnnotation)
        XCTAssertEqual(vm.name, "")
        XCTAssertTrue(vm.qualifierPairs.isEmpty)
        XCTAssertTrue(vm.dbxrefLinks.isEmpty)
        XCTAssertNil(vm.fullTranslation)
        XCTAssertFalse(vm.isTranslationVisible)
    }

    // MARK: - Qualifier ordering

    func testQualifierPairsAreOrdered() {
        let vm = SelectionSectionViewModel()

        // Provide qualifiers in random order
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            chromosome: "chr1",
            intervals: [AnnotationInterval(start: 100, end: 500)],
            strand: .forward,
            qualifiers: [
                "extra": AnnotationQualifier("note=some%20note;gene=TEST;product=test%20protein;description=a%20description")
            ]
        )

        vm.select(annotation: annotation)

        let keys = vm.qualifierPairs.map(\.key)
        // gene, product, description should come before note (display order priority)
        if let geneIdx = keys.firstIndex(of: "Gene"),
           let productIdx = keys.firstIndex(of: "Product"),
           let descIdx = keys.firstIndex(of: "Description"),
           let noteIdx = keys.firstIndex(of: "Note") {
            XCTAssertLessThan(geneIdx, noteIdx, "Gene should come before Note")
            XCTAssertLessThan(productIdx, noteIdx, "Product should come before Note")
            XCTAssertLessThan(descIdx, noteIdx, "Description should come before Note")
        } else {
            XCTFail("Expected all qualifier keys to be present")
        }
    }
}
