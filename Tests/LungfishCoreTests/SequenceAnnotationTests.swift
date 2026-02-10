// SequenceAnnotationTests.swift - Tests for SequenceAnnotation model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SequenceAnnotationTests: XCTestCase {

    // MARK: - Creation Tests

    func testCreateSingleIntervalAnnotation() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 2000
        )

        XCTAssertEqual(annotation.type, .gene)
        XCTAssertEqual(annotation.name, "BRCA1")
        XCTAssertEqual(annotation.start, 1000)
        XCTAssertEqual(annotation.end, 2000)
        XCTAssertEqual(annotation.totalLength, 1000)
        XCTAssertFalse(annotation.isDiscontinuous)
    }

    func testCreateMultiIntervalAnnotation() {
        let intervals = [
            AnnotationInterval(start: 1000, end: 1500),
            AnnotationInterval(start: 2000, end: 2500),
            AnnotationInterval(start: 3000, end: 3500)
        ]

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "CDS1",
            intervals: intervals
        )

        XCTAssertTrue(annotation.isDiscontinuous)
        XCTAssertEqual(annotation.intervals.count, 3)
        XCTAssertEqual(annotation.totalLength, 1500)  // 500 + 500 + 500
    }

    func testCreateAnnotationWithStrand() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "forward_gene",
            start: 1000,
            end: 2000,
            strand: .forward
        )

        XCTAssertEqual(annotation.strand, .forward)
    }

    func testCreateAnnotationWithReverseStrand() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "reverse_gene",
            start: 1000,
            end: 2000,
            strand: .reverse
        )

        XCTAssertEqual(annotation.strand, .reverse)
    }

    func testCreateAnnotationWithUnknownStrand() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "unknown_strand",
            start: 1000,
            end: 2000
        )

        XCTAssertEqual(annotation.strand, .unknown)
    }

    func testCreateAnnotationWithQualifiers() {
        let qualifiers: [String: AnnotationQualifier] = [
            "gene": AnnotationQualifier("BRCA1"),
            "product": AnnotationQualifier("breast cancer type 1 susceptibility protein"),
            "db_xref": AnnotationQualifier(["GeneID:672", "HGNC:1100"])
        ]

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 2000,
            qualifiers: qualifiers
        )

        XCTAssertEqual(annotation.qualifier("gene"), "BRCA1")
        XCTAssertEqual(annotation.qualifier("product"), "breast cancer type 1 susceptibility protein")
        XCTAssertEqual(annotation.qualifierValues("db_xref").count, 2)
    }

    func testCreateAnnotationWithColor() {
        let color = AnnotationColor(red: 0.8, green: 0.2, blue: 0.4)

        let annotation = SequenceAnnotation(
            type: .primer,
            name: "forward_primer",
            start: 100,
            end: 120,
            color: color
        )

        XCTAssertNotNil(annotation.color)
        XCTAssertEqual(annotation.color?.red, 0.8)
    }

    func testCreateAnnotationWithNote() {
        let annotation = SequenceAnnotation(
            type: .misc_feature,
            name: "feature1",
            start: 100,
            end: 200,
            note: "This is a test feature"
        )

        XCTAssertEqual(annotation.note, "This is a test feature")
    }

    func testCreateAnnotationWithParentID() {
        let parentID = UUID()
        let annotation = SequenceAnnotation(
            type: .exon,
            name: "exon1",
            start: 1000,
            end: 1500,
            parentID: parentID
        )

        XCTAssertEqual(annotation.parentID, parentID)
    }

    // MARK: - Interval Tests

    func testIntervalsAreSorted() {
        let intervals = [
            AnnotationInterval(start: 3000, end: 3500),
            AnnotationInterval(start: 1000, end: 1500),
            AnnotationInterval(start: 2000, end: 2500)
        ]

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "unsorted",
            intervals: intervals
        )

        // Intervals should be sorted by start position
        XCTAssertEqual(annotation.intervals[0].start, 1000)
        XCTAssertEqual(annotation.intervals[1].start, 2000)
        XCTAssertEqual(annotation.intervals[2].start, 3000)
    }

    func testBoundingRegion() {
        let intervals = [
            AnnotationInterval(start: 1000, end: 1500),
            AnnotationInterval(start: 3000, end: 3500)
        ]

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: intervals
        )

        let bounding = annotation.boundingRegion
        XCTAssertEqual(bounding.start, 1000)
        XCTAssertEqual(bounding.end, 3500)
    }

    func testStartAndEnd() {
        let intervals = [
            AnnotationInterval(start: 1000, end: 1500),
            AnnotationInterval(start: 3000, end: 3500)
        ]

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: intervals
        )

        XCTAssertEqual(annotation.start, 1000)
        XCTAssertEqual(annotation.end, 3500)
    }

    // MARK: - Overlap Tests

    func testOverlapsSingleInterval() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            start: 1000,
            end: 2000
        )

        // Overlapping cases
        XCTAssertTrue(annotation.overlaps(start: 1500, end: 2500))
        XCTAssertTrue(annotation.overlaps(start: 500, end: 1500))
        XCTAssertTrue(annotation.overlaps(start: 1200, end: 1800))
        XCTAssertTrue(annotation.overlaps(start: 500, end: 2500))

        // Non-overlapping cases
        XCTAssertFalse(annotation.overlaps(start: 0, end: 999))
        XCTAssertFalse(annotation.overlaps(start: 2001, end: 3000))
    }

    func testOverlapsMultiInterval() {
        let intervals = [
            AnnotationInterval(start: 1000, end: 1500),
            AnnotationInterval(start: 2000, end: 2500)
        ]

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "test",
            intervals: intervals
        )

        // Overlaps first interval
        XCTAssertTrue(annotation.overlaps(start: 1200, end: 1300))

        // Overlaps second interval
        XCTAssertTrue(annotation.overlaps(start: 2200, end: 2300))

        // Falls in gap - should not overlap
        XCTAssertFalse(annotation.overlaps(start: 1600, end: 1900))

        // Before first interval
        XCTAssertFalse(annotation.overlaps(start: 0, end: 900))

        // After last interval
        XCTAssertFalse(annotation.overlaps(start: 2600, end: 3000))
    }

    func testOverlapsEdgeCases() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            start: 1000,
            end: 2000
        )

        // Adjacent but not overlapping
        XCTAssertFalse(annotation.overlaps(start: 2000, end: 3000))
        XCTAssertFalse(annotation.overlaps(start: 0, end: 1000))

        // Touching by one base
        XCTAssertTrue(annotation.overlaps(start: 1999, end: 3000))
        XCTAssertTrue(annotation.overlaps(start: 0, end: 1001))
    }

    // MARK: - Qualifier Tests

    func testQualifierSingleValue() {
        let qualifiers: [String: AnnotationQualifier] = [
            "gene": AnnotationQualifier("BRCA1")
        ]

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 2000,
            qualifiers: qualifiers
        )

        XCTAssertEqual(annotation.qualifier("gene"), "BRCA1")
        XCTAssertTrue(annotation.qualifiers["gene"]?.isSingleValued ?? false)
    }

    func testQualifierMultiValue() {
        let qualifiers: [String: AnnotationQualifier] = [
            "db_xref": AnnotationQualifier(["GeneID:672", "HGNC:1100", "MIM:113705"])
        ]

        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            start: 1000,
            end: 2000,
            qualifiers: qualifiers
        )

        let values = annotation.qualifierValues("db_xref")
        XCTAssertEqual(values.count, 3)
        XCTAssertTrue(values.contains("GeneID:672"))
        XCTAssertFalse(annotation.qualifiers["db_xref"]?.isSingleValued ?? true)
    }

    func testQualifierNotFound() {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "test",
            start: 1000,
            end: 2000
        )

        XCTAssertNil(annotation.qualifier("nonexistent"))
        XCTAssertTrue(annotation.qualifierValues("nonexistent").isEmpty)
    }

    // MARK: - AnnotationInterval Tests

    func testAnnotationIntervalCreation() {
        let interval = AnnotationInterval(start: 100, end: 200)
        XCTAssertEqual(interval.start, 100)
        XCTAssertEqual(interval.end, 200)
        XCTAssertEqual(interval.length, 100)
    }

    func testAnnotationIntervalWithPhase() {
        let interval = AnnotationInterval(start: 100, end: 200, phase: 1)
        XCTAssertEqual(interval.phase, 1)
    }

    func testAnnotationIntervalComparable() {
        let interval1 = AnnotationInterval(start: 100, end: 200)
        let interval2 = AnnotationInterval(start: 200, end: 300)
        let interval3 = AnnotationInterval(start: 100, end: 300)

        XCTAssertTrue(interval1 < interval2)
        XCTAssertTrue(interval1 < interval3)  // Same start, shorter end
    }

    func testAnnotationIntervalSorting() {
        let intervals = [
            AnnotationInterval(start: 300, end: 400),
            AnnotationInterval(start: 100, end: 200),
            AnnotationInterval(start: 200, end: 300)
        ]

        let sorted = intervals.sorted()
        XCTAssertEqual(sorted[0].start, 100)
        XCTAssertEqual(sorted[1].start, 200)
        XCTAssertEqual(sorted[2].start, 300)
    }

    func testAnnotationIntervalZeroLength() {
        let interval = AnnotationInterval(start: 100, end: 100)
        XCTAssertEqual(interval.length, 0)
    }

    // MARK: - AnnotationType Tests

    func testAnnotationTypeRawValues() {
        XCTAssertEqual(AnnotationType.gene.rawValue, "gene")
        XCTAssertEqual(AnnotationType.cds.rawValue, "CDS")
        XCTAssertEqual(AnnotationType.utr5.rawValue, "5'UTR")
        XCTAssertEqual(AnnotationType.utr3.rawValue, "3'UTR")
        XCTAssertEqual(AnnotationType.snp.rawValue, "SNP")
    }

    func testAnnotationTypeDefaultColors() {
        // Test that default colors exist and are reasonable
        let geneColor = AnnotationType.gene.defaultColor
        XCTAssertTrue(geneColor.red >= 0 && geneColor.red <= 1)
        XCTAssertTrue(geneColor.green >= 0 && geneColor.green <= 1)
        XCTAssertTrue(geneColor.blue >= 0 && geneColor.blue <= 1)

        let cdsColor = AnnotationType.cds.defaultColor
        XCTAssertNotEqual(cdsColor, geneColor)  // Different types should have different colors
    }

    func testAnnotationTypeCaseIterable() {
        let allTypes = AnnotationType.allCases
        XCTAssertTrue(allTypes.contains(.gene))
        XCTAssertTrue(allTypes.contains(.cds))
        XCTAssertTrue(allTypes.contains(.exon))
        XCTAssertTrue(allTypes.contains(.primer))
    }

    // MARK: - AnnotationQualifier Tests

    func testAnnotationQualifierSingleValue() {
        let qualifier = AnnotationQualifier("single_value")
        XCTAssertEqual(qualifier.firstValue, "single_value")
        XCTAssertEqual(qualifier.values.count, 1)
        XCTAssertTrue(qualifier.isSingleValued)
    }

    func testAnnotationQualifierMultiValue() {
        let qualifier = AnnotationQualifier(["value1", "value2", "value3"])
        XCTAssertEqual(qualifier.firstValue, "value1")
        XCTAssertEqual(qualifier.values.count, 3)
        XCTAssertFalse(qualifier.isSingleValued)
    }

    func testAnnotationQualifierEmptyArray() {
        let qualifier = AnnotationQualifier([])
        XCTAssertNil(qualifier.firstValue)
        XCTAssertTrue(qualifier.values.isEmpty)
    }

    // MARK: - AnnotationColor Tests

    func testAnnotationColorCreation() {
        let color = AnnotationColor(red: 0.5, green: 0.6, blue: 0.7)
        XCTAssertEqual(color.red, 0.5)
        XCTAssertEqual(color.green, 0.6)
        XCTAssertEqual(color.blue, 0.7)
        XCTAssertEqual(color.alpha, 1.0)
    }

    func testAnnotationColorWithAlpha() {
        let color = AnnotationColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.8)
        XCTAssertEqual(color.alpha, 0.8)
    }

    func testAnnotationColorClamping() {
        // Values should be clamped to 0-1 range
        let color = AnnotationColor(red: 1.5, green: -0.5, blue: 0.5, alpha: 2.0)
        XCTAssertEqual(color.red, 1.0)
        XCTAssertEqual(color.green, 0.0)
        XCTAssertEqual(color.blue, 0.5)
        XCTAssertEqual(color.alpha, 1.0)
    }

    func testAnnotationColorFromHex() {
        let color = AnnotationColor(hex: "#FF5500")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.red, 1.0)
        if let green = color?.green {
            XCTAssertEqual(green, 85.0/255.0, accuracy: 0.01)
        }
        XCTAssertEqual(color?.blue, 0.0)
    }

    func testAnnotationColorFromHexWithoutHash() {
        let color = AnnotationColor(hex: "FF5500")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.red, 1.0)
    }

    func testAnnotationColorFromHexBlack() {
        let color = AnnotationColor(hex: "#000000")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.red, 0.0)
        XCTAssertEqual(color?.green, 0.0)
        XCTAssertEqual(color?.blue, 0.0)
    }

    func testAnnotationColorFromHexWhite() {
        let color = AnnotationColor(hex: "#FFFFFF")
        XCTAssertNotNil(color)
        XCTAssertEqual(color?.red, 1.0)
        XCTAssertEqual(color?.green, 1.0)
        XCTAssertEqual(color?.blue, 1.0)
    }

    func testAnnotationColorFromHexInvalid() {
        XCTAssertNil(AnnotationColor(hex: "invalid"))
        XCTAssertNil(AnnotationColor(hex: "#GGG"))
        XCTAssertNil(AnnotationColor(hex: "#12345"))  // Too short
        XCTAssertNil(AnnotationColor(hex: "#1234567"))  // Too long
    }

    func testAnnotationColorHexString() {
        let color = AnnotationColor(red: 1.0, green: 0.0, blue: 0.5)
        let hex = color.hexString
        XCTAssertTrue(hex.hasPrefix("#"))
        XCTAssertEqual(hex.count, 7)
    }

    func testAnnotationColorHexRoundTrip() {
        let original = AnnotationColor(red: 0.8, green: 0.4, blue: 0.2)
        let hex = original.hexString
        let restored = AnnotationColor(hex: hex)

        XCTAssertNotNil(restored)
        XCTAssertEqual(original.red, restored!.red, accuracy: 0.01)
        XCTAssertEqual(original.green, restored!.green, accuracy: 0.01)
        XCTAssertEqual(original.blue, restored!.blue, accuracy: 0.01)
    }

    func testAnnotationColorHashable() {
        let color1 = AnnotationColor(red: 0.5, green: 0.5, blue: 0.5)
        let color2 = AnnotationColor(red: 0.5, green: 0.5, blue: 0.5)
        let color3 = AnnotationColor(red: 0.6, green: 0.5, blue: 0.5)

        var set = Set<AnnotationColor>()
        set.insert(color1)

        XCTAssertTrue(set.contains(color2))
        XCTAssertFalse(set.contains(color3))
    }

    // MARK: - Codable Tests

    func testAnnotationCodable() throws {
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 2000,
            strand: .forward,
            qualifiers: ["gene": AnnotationQualifier("BRCA1")],
            color: AnnotationColor(red: 0.5, green: 0.5, blue: 0.5),
            note: "Test annotation"
        )

        let encoded = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(SequenceAnnotation.self, from: encoded)

        XCTAssertEqual(decoded.name, annotation.name)
        XCTAssertEqual(decoded.type, annotation.type)
        XCTAssertEqual(decoded.start, annotation.start)
        XCTAssertEqual(decoded.end, annotation.end)
        XCTAssertEqual(decoded.strand, annotation.strand)
        XCTAssertEqual(decoded.note, annotation.note)
    }

    func testMultiIntervalAnnotationCodable() throws {
        let intervals = [
            AnnotationInterval(start: 1000, end: 1500, phase: 0),
            AnnotationInterval(start: 2000, end: 2500, phase: 1)
        ]

        let annotation = SequenceAnnotation(
            type: .cds,
            name: "CDS1",
            intervals: intervals,
            strand: .forward
        )

        let encoded = try JSONEncoder().encode(annotation)
        let decoded = try JSONDecoder().decode(SequenceAnnotation.self, from: encoded)

        XCTAssertEqual(decoded.intervals.count, 2)
        XCTAssertEqual(decoded.intervals[0].phase, 0)
        XCTAssertEqual(decoded.intervals[1].phase, 1)
    }

    func testAnnotationColorCodable() throws {
        let color = AnnotationColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 0.8)

        let encoded = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(AnnotationColor.self, from: encoded)

        XCTAssertEqual(decoded.red, color.red)
        XCTAssertEqual(decoded.green, color.green)
        XCTAssertEqual(decoded.blue, color.blue)
        XCTAssertEqual(decoded.alpha, color.alpha)
    }

    func testAnnotationQualifierCodable() throws {
        let qualifier = AnnotationQualifier(["value1", "value2"])

        let encoded = try JSONEncoder().encode(qualifier)
        let decoded = try JSONDecoder().decode(AnnotationQualifier.self, from: encoded)

        XCTAssertEqual(decoded.values, qualifier.values)
    }

    // MARK: - New AnnotationType Cases Tests

    func testNewAnnotationTypesExist() {
        // Verify all new protein processing types
        XCTAssertEqual(AnnotationType.mat_peptide.rawValue, "mat_peptide")
        XCTAssertEqual(AnnotationType.sig_peptide.rawValue, "sig_peptide")
        XCTAssertEqual(AnnotationType.transit_peptide.rawValue, "transit_peptide")

        // Verify new regulatory types
        XCTAssertEqual(AnnotationType.regulatory.rawValue, "regulatory")
        XCTAssertEqual(AnnotationType.ncRNA.rawValue, "ncRNA")

        // Verify new binding types
        XCTAssertEqual(AnnotationType.misc_binding.rawValue, "misc_binding")
        XCTAssertEqual(AnnotationType.protein_bind.rawValue, "protein_bind")

        // Verify they are all in CaseIterable
        let allCases = AnnotationType.allCases
        XCTAssertTrue(allCases.contains(.mat_peptide))
        XCTAssertTrue(allCases.contains(.sig_peptide))
        XCTAssertTrue(allCases.contains(.transit_peptide))
        XCTAssertTrue(allCases.contains(.regulatory))
        XCTAssertTrue(allCases.contains(.ncRNA))
        XCTAssertTrue(allCases.contains(.misc_binding))
        XCTAssertTrue(allCases.contains(.protein_bind))
    }

    func testAnnotationTypeColorsDistinct() {
        // Every type should have a distinct default color (no two types share the same RGB)
        var colorsByRGB: [String: AnnotationType] = [:]
        var duplicates: [(AnnotationType, AnnotationType, String)] = []

        for type in AnnotationType.allCases {
            let color = type.defaultColor
            let key = String(format: "%.2f,%.2f,%.2f", color.red, color.green, color.blue)
            if let existing = colorsByRGB[key] {
                duplicates.append((existing, type, key))
            } else {
                colorsByRGB[key] = type
            }
        }

        // Some deliberate sharing is acceptable (utr5/utr3, snp/variation, primer/primerPair)
        // but we should have far fewer duplicates than types
        let allowedSharing: Set<String> = [
            "5'UTR|3'UTR", "3'UTR|5'UTR",
            "SNP|variation", "variation|SNP",
            "primer|primer_pair", "primer_pair|primer",
        ]
        let unexpectedDuplicates = duplicates.filter { dup in
            let pair1 = "\(dup.0.rawValue)|\(dup.1.rawValue)"
            let pair2 = "\(dup.1.rawValue)|\(dup.0.rawValue)"
            return !allowedSharing.contains(pair1) && !allowedSharing.contains(pair2)
        }

        XCTAssertTrue(unexpectedDuplicates.isEmpty,
                      "Unexpected color duplicates: \(unexpectedDuplicates.map { "\($0.0.rawValue) and \($0.1.rawValue) both use \($0.2)" }.joined(separator: "; "))")
    }

    func testNewAnnotationTypeColors() {
        // Each new type should have a non-gray, distinct color
        let newTypes: [AnnotationType] = [
            .mat_peptide, .sig_peptide, .transit_peptide,
            .regulatory, .ncRNA, .misc_binding, .protein_bind
        ]

        for type in newTypes {
            let color = type.defaultColor
            // Colors should be in valid range
            XCTAssertTrue(color.red >= 0 && color.red <= 1, "\(type.rawValue) red out of range")
            XCTAssertTrue(color.green >= 0 && color.green <= 1, "\(type.rawValue) green out of range")
            XCTAssertTrue(color.blue >= 0 && color.blue <= 1, "\(type.rawValue) blue out of range")

            // Should not be plain gray (i.e., not all components equal)
            let isGray = abs(color.red - color.green) < 0.01 && abs(color.green - color.blue) < 0.01
            XCTAssertFalse(isGray, "\(type.rawValue) has a gray color — should be distinct")
        }
    }

    // MARK: - AnnotationType.from(rawString:) Tests

    func testAnnotationTypeFromRawStringExactMatch() {
        // Exact rawValue matches
        XCTAssertEqual(AnnotationType.from(rawString: "gene"), .gene)
        XCTAssertEqual(AnnotationType.from(rawString: "CDS"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "5'UTR"), .utr5)
        XCTAssertEqual(AnnotationType.from(rawString: "3'UTR"), .utr3)
        XCTAssertEqual(AnnotationType.from(rawString: "SNP"), .snp)
        XCTAssertEqual(AnnotationType.from(rawString: "polyA_signal"), .polyASignal)
        XCTAssertEqual(AnnotationType.from(rawString: "mat_peptide"), .mat_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "regulatory"), .regulatory)
        XCTAssertEqual(AnnotationType.from(rawString: "ncRNA"), .ncRNA)
    }

    func testAnnotationTypeFromRawStringCaseInsensitive() {
        // Case-insensitive matches
        XCTAssertEqual(AnnotationType.from(rawString: "cds"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "Cds"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "GENE"), .gene)
        XCTAssertEqual(AnnotationType.from(rawString: "mRNA"), .mRNA)
        XCTAssertEqual(AnnotationType.from(rawString: "mrna"), .mRNA)
        XCTAssertEqual(AnnotationType.from(rawString: "MRNA"), .mRNA)
        XCTAssertEqual(AnnotationType.from(rawString: "ncrna"), .ncRNA)
        XCTAssertEqual(AnnotationType.from(rawString: "NCRNA"), .ncRNA)
    }

    func testAnnotationTypeFromRawStringGenBankTypes() {
        // Common GenBank feature type strings
        XCTAssertEqual(AnnotationType.from(rawString: "gene"), .gene)
        XCTAssertEqual(AnnotationType.from(rawString: "CDS"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "mRNA"), .mRNA)
        XCTAssertEqual(AnnotationType.from(rawString: "exon"), .exon)
        XCTAssertEqual(AnnotationType.from(rawString: "intron"), .intron)
        XCTAssertEqual(AnnotationType.from(rawString: "mat_peptide"), .mat_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "sig_peptide"), .sig_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "transit_peptide"), .transit_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "regulatory"), .regulatory)
        XCTAssertEqual(AnnotationType.from(rawString: "misc_feature"), .misc_feature)
        XCTAssertEqual(AnnotationType.from(rawString: "primer_bind"), .primer)
        XCTAssertEqual(AnnotationType.from(rawString: "repeat_region"), .repeatRegion)
        XCTAssertEqual(AnnotationType.from(rawString: "stem_loop"), .stem_loop)
        XCTAssertEqual(AnnotationType.from(rawString: "variation"), .variation)
        XCTAssertEqual(AnnotationType.from(rawString: "promoter"), .promoter)
        XCTAssertEqual(AnnotationType.from(rawString: "enhancer"), .enhancer)
        XCTAssertEqual(AnnotationType.from(rawString: "misc_binding"), .misc_binding)
        XCTAssertEqual(AnnotationType.from(rawString: "protein_bind"), .protein_bind)
    }

    func testAnnotationTypeFromRawStringGFF3Aliases() {
        // GFF3-specific type names
        XCTAssertEqual(AnnotationType.from(rawString: "five_prime_utr"), .utr5)
        XCTAssertEqual(AnnotationType.from(rawString: "three_prime_utr"), .utr3)
        XCTAssertEqual(AnnotationType.from(rawString: "coding_sequence"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "5'utr"), .utr5)
        XCTAssertEqual(AnnotationType.from(rawString: "3'utr"), .utr3)
    }

    func testAnnotationTypeFromRawStringReturnsNilForUnknown() {
        XCTAssertNil(AnnotationType.from(rawString: "unknown_type"))
        XCTAssertNil(AnnotationType.from(rawString: ""))
        XCTAssertNil(AnnotationType.from(rawString: "UNKNOWN"))
        XCTAssertNil(AnnotationType.from(rawString: "hypothetical_protein"))
    }

    func testAnnotationTypeFromRawStringCoversAllCases() {
        // Every AnnotationType case should be reachable via from(rawString:) using its rawValue
        for type in AnnotationType.allCases {
            if type == .custom { continue } // custom is special
            let result = AnnotationType.from(rawString: type.rawValue)
            XCTAssertEqual(result, type, "from(rawString: \"\(type.rawValue)\") should return .\(type)")
        }
    }

    // MARK: - Improved Color Differentiation Tests

    func testEnhancerHasDistinctColorFromPromoter() {
        let promoterColor = AnnotationType.promoter.defaultColor
        let enhancerColor = AnnotationType.enhancer.defaultColor
        XCTAssertNotEqual(promoterColor, enhancerColor,
                          "Enhancer and promoter should have distinct colors")
    }

    func testInsertionAndDeletionHaveDistinctColors() {
        let insertionColor = AnnotationType.insertion.defaultColor
        let deletionColor = AnnotationType.deletion.defaultColor
        XCTAssertNotEqual(insertionColor, deletionColor,
                          "Insertion and deletion should have distinct colors")
    }

    func testAnnotationTypeFromRawStringMixedCaseAliases() {
        // Verify case-insensitive matching works for GFF3/GenBank aliases
        XCTAssertEqual(AnnotationType.from(rawString: "CODING_SEQUENCE"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "Coding_Sequence"), .cds)
        XCTAssertEqual(AnnotationType.from(rawString: "FIVE_PRIME_UTR"), .utr5)
        XCTAssertEqual(AnnotationType.from(rawString: "THREE_PRIME_UTR"), .utr3)
        XCTAssertEqual(AnnotationType.from(rawString: "PRIMER_BIND"), .primer)
        XCTAssertEqual(AnnotationType.from(rawString: "MAT_PEPTIDE"), .mat_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "SIG_PEPTIDE"), .sig_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "TRANSIT_PEPTIDE"), .transit_peptide)
        XCTAssertEqual(AnnotationType.from(rawString: "REGULATORY"), .regulatory)
        XCTAssertEqual(AnnotationType.from(rawString: "MISC_BINDING"), .misc_binding)
        XCTAssertEqual(AnnotationType.from(rawString: "PROTEIN_BIND"), .protein_bind)
        XCTAssertEqual(AnnotationType.from(rawString: "REPEAT_REGION"), .repeatRegion)
        XCTAssertEqual(AnnotationType.from(rawString: "STEM_LOOP"), .stem_loop)
        XCTAssertEqual(AnnotationType.from(rawString: "MISC_FEATURE"), .misc_feature)
        XCTAssertEqual(AnnotationType.from(rawString: "POLYA_SIGNAL"), .polyASignal)
    }

    func testAnnotationTypeFromRawStringCustom() {
        // .custom has rawValue "custom" — the rawValue init path should find it
        let result = AnnotationType.from(rawString: "custom")
        XCTAssertEqual(result, .custom)

        // "Custom" should return nil (no case in switch, rawValue init is case-sensitive)
        XCTAssertNil(AnnotationType.from(rawString: "Custom"))
    }

    func testNewAnnotationTypesCodableRoundTrip() throws {
        let newTypes: [AnnotationType] = [
            .mat_peptide, .sig_peptide, .transit_peptide,
            .regulatory, .ncRNA, .misc_binding, .protein_bind
        ]

        for type in newTypes {
            let annotation = SequenceAnnotation(
                type: type,
                name: "test_\(type.rawValue)",
                start: 100,
                end: 200,
                strand: .forward
            )

            let encoded = try JSONEncoder().encode(annotation)
            let decoded = try JSONDecoder().decode(SequenceAnnotation.self, from: encoded)

            XCTAssertEqual(decoded.type, type,
                           "\(type.rawValue) should survive JSON round trip")
            XCTAssertEqual(decoded.name, "test_\(type.rawValue)")
        }
    }

    // MARK: - Gene Structure Hierarchy Tests

    func testGeneHierarchy() {
        let geneID = UUID()

        let gene = SequenceAnnotation(
            id: geneID,
            type: .gene,
            name: "test_gene",
            start: 1000,
            end: 5000
        )

        let mrna = SequenceAnnotation(
            type: .mRNA,
            name: "test_mrna",
            start: 1000,
            end: 5000,
            parentID: geneID
        )

        let exon1 = SequenceAnnotation(
            type: .exon,
            name: "exon1",
            start: 1000,
            end: 1500,
            parentID: mrna.id
        )

        let exon2 = SequenceAnnotation(
            type: .exon,
            name: "exon2",
            start: 2000,
            end: 2500,
            parentID: mrna.id
        )

        XCTAssertEqual(mrna.parentID, gene.id)
        XCTAssertEqual(exon1.parentID, mrna.id)
        XCTAssertEqual(exon2.parentID, mrna.id)
    }
}
