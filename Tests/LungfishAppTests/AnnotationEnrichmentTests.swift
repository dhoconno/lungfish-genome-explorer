// AnnotationEnrichmentTests.swift - Tests for annotation type enrichment from SQLite
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishIO

/// Tests the annotation type enrichment logic used in fetchAnnotationsAsync.
///
/// When BigBed features are read, their types are inferred heuristically.
/// The SQLite annotation database stores the authoritative GenBank/GFF3 type.
/// The enrichment step overrides inferred types with database types where available.
final class AnnotationEnrichmentTests: XCTestCase {

    // MARK: - Enrichment Pattern Tests

    /// Simulates the enrichment loop from fetchAnnotationsAsync:
    /// annotations with inferred types get corrected by database records.
    func testEnrichmentOverridesInferredType() {
        // Simulate BigBed annotations with heuristic-inferred types
        var annotations = [
            makeAnnotation(name: "gag", start: 336, end: 1838, type: .gene),
            makeAnnotation(name: "pol", start: 1631, end: 4642, type: .gene),
            makeAnnotation(name: "p17", start: 336, end: 732, type: .exon), // inferred from size
        ]

        // Simulate SQLite database records with authoritative types
        let dbRecords: [(name: String, start: Int, end: Int, type: String)] = [
            ("gag", 336, 1838, "gene"),
            ("pol", 1631, 4642, "CDS"),
            ("p17", 336, 732, "mat_peptide"),
        ]

        // Build lookup (same pattern as fetchAnnotationsAsync)
        var typeLookup: [String: String] = [:]
        for record in dbRecords {
            let key = "\(record.name)|\(record.start)|\(record.end)"
            typeLookup[key] = record.type
        }

        // Enrich (same pattern as fetchAnnotationsAsync)
        var enrichedCount = 0
        for i in annotations.indices {
            let ann = annotations[i]
            let firstStart = ann.intervals.first!.start
            let lastEnd = ann.intervals.last!.end
            let key = "\(ann.name)|\(firstStart)|\(lastEnd)"
            if let dbType = typeLookup[key],
               let mapped = AnnotationType.from(rawString: dbType),
               mapped != ann.type {
                annotations[i].type = mapped
                annotations[i].color = nil
                enrichedCount += 1
            }
        }

        // gag was already .gene → no change needed
        XCTAssertEqual(annotations[0].type, .gene)
        // pol was .gene but should be .cds
        XCTAssertEqual(annotations[1].type, .cds)
        // p17 was .exon but should be .mat_peptide
        XCTAssertEqual(annotations[2].type, .mat_peptide)
        // Only pol and p17 were enriched (gag already matched)
        XCTAssertEqual(enrichedCount, 2)
    }

    /// Enrichment clears explicit color so it falls back to type.defaultColor.
    func testEnrichmentClearsExplicitColor() {
        var annotations = [
            makeAnnotation(
                name: "vpu",
                start: 6045,
                end: 6310,
                type: .gene,
                color: AnnotationColor(red: 0.5, green: 0.5, blue: 0.5) // arbitrary color
            ),
        ]

        let dbRecords: [(name: String, start: Int, end: Int, type: String)] = [
            ("vpu", 6045, 6310, "CDS"),
        ]

        var typeLookup: [String: String] = [:]
        for record in dbRecords {
            typeLookup["\(record.name)|\(record.start)|\(record.end)"] = record.type
        }

        for i in annotations.indices {
            let ann = annotations[i]
            let key = "\(ann.name)|\(ann.intervals.first!.start)|\(ann.intervals.last!.end)"
            if let dbType = typeLookup[key],
               let mapped = AnnotationType.from(rawString: dbType),
               mapped != ann.type {
                annotations[i].type = mapped
                annotations[i].color = nil
            }
        }

        XCTAssertEqual(annotations[0].type, .cds)
        XCTAssertNil(annotations[0].color, "Explicit color should be cleared after enrichment")
    }

    /// Annotations not found in the database retain their inferred type.
    func testEnrichmentSkipsMissingAnnotations() {
        var annotations = [
            makeAnnotation(name: "LOC123456", start: 1000, end: 5000, type: .gene),
        ]

        // Empty database
        let typeLookup: [String: String] = [:]

        for i in annotations.indices {
            let ann = annotations[i]
            let key = "\(ann.name)|\(ann.intervals.first!.start)|\(ann.intervals.last!.end)"
            if let dbType = typeLookup[key],
               let mapped = AnnotationType.from(rawString: dbType),
               mapped != ann.type {
                annotations[i].type = mapped
                annotations[i].color = nil
            }
        }

        XCTAssertEqual(annotations[0].type, .gene, "Type should be unchanged when not in database")
    }

    /// Multi-interval annotations use first.start and last.end for the lookup key.
    func testEnrichmentUsesCorrectKeyForMultiBlockFeatures() {
        var annotations = [
            SequenceAnnotation(
                type: .gene, // inferred
                name: "gag-pol",
                chromosome: "NC_001802.1",
                intervals: [
                    AnnotationInterval(start: 336, end: 1838),
                    AnnotationInterval(start: 1838, end: 4642),
                ],
                strand: .forward,
                qualifiers: [:],
                color: nil
            ),
        ]

        // Database has the correct type with coordinates matching first/last interval
        let typeLookup: [String: String] = [
            "gag-pol|336|4642": "CDS",
        ]

        for i in annotations.indices {
            let ann = annotations[i]
            let firstStart = ann.intervals.first!.start
            let lastEnd = ann.intervals.last!.end
            let key = "\(ann.name)|\(firstStart)|\(lastEnd)"
            if let dbType = typeLookup[key],
               let mapped = AnnotationType.from(rawString: dbType),
               mapped != ann.type {
                annotations[i].type = mapped
                annotations[i].color = nil
            }
        }

        XCTAssertEqual(annotations[0].type, .cds)
    }

    /// When the database type string doesn't map to any AnnotationType,
    /// the annotation retains its inferred type.
    func testEnrichmentIgnoresUnknownDatabaseTypes() {
        var annotations = [
            makeAnnotation(name: "hypothetical", start: 100, end: 500, type: .gene),
        ]

        let typeLookup: [String: String] = [
            "hypothetical|100|500": "hypothetical_protein", // not a recognized type
        ]

        for i in annotations.indices {
            let ann = annotations[i]
            let key = "\(ann.name)|\(ann.intervals.first!.start)|\(ann.intervals.last!.end)"
            if let dbType = typeLookup[key],
               let mapped = AnnotationType.from(rawString: dbType),
               mapped != ann.type {
                annotations[i].type = mapped
                annotations[i].color = nil
            }
        }

        XCTAssertEqual(annotations[0].type, .gene, "Unknown database type should not change annotation")
    }

    // MARK: - Integration with AnnotationDatabase.queryByRegion

    /// End-to-end: create a database, query by region, and use results to enrich annotations.
    func testEnrichmentFromRealDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrichment_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create BED14 file with authoritative types
        let bedContent = [
            "NC_001802.1\t336\t1838\tgag\t0\t+\t336\t1838\t0,0,0\t1\t1502\t0\tgene\tgene=gag",
            "NC_001802.1\t1631\t4642\tpol\t0\t+\t1631\t4642\t0,0,0\t1\t3011\t0\tCDS\tgene=pol;protein_id=NP_001",
            "NC_001802.1\t336\t732\tp17\t0\t+\t336\t732\t0,0,0\t1\t396\t0\tmat_peptide\tproduct=matrix%20protein",
            "NC_001802.1\t6045\t6310\tvpu\t0\t+\t6045\t6310\t0,0,0\t1\t265\t0\tCDS\tgene=vpu",
        ].joined(separator: "\n")

        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)

        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)

        let db = try AnnotationDatabase(url: dbURL)

        // Simulate BigBed annotations with inferred types
        var annotations = [
            makeAnnotation(name: "gag", start: 336, end: 1838, type: .gene),
            makeAnnotation(name: "pol", start: 1631, end: 4642, type: .gene), // should be CDS
            makeAnnotation(name: "p17", start: 336, end: 732, type: .exon),   // should be mat_peptide
            makeAnnotation(name: "vpu", start: 6045, end: 6310, type: .gene), // should be CDS
        ]

        // Query database for region (same as fetchAnnotationsAsync)
        let dbRecords = db.queryByRegion(chromosome: "NC_001802.1", start: 0, end: 10000)

        var typeLookup: [String: String] = [:]
        for record in dbRecords {
            let key = "\(record.name)|\(record.start)|\(record.end)"
            typeLookup[key] = record.type
        }

        var enrichedCount = 0
        for i in annotations.indices {
            let ann = annotations[i]
            let key = "\(ann.name)|\(ann.intervals.first!.start)|\(ann.intervals.last!.end)"
            if let dbType = typeLookup[key],
               let mapped = AnnotationType.from(rawString: dbType),
               mapped != ann.type {
                annotations[i].type = mapped
                annotations[i].color = nil
                enrichedCount += 1
            }
        }

        XCTAssertEqual(annotations[0].type, .gene, "gag was already .gene")
        XCTAssertEqual(annotations[1].type, .cds, "pol should be enriched to .cds")
        XCTAssertEqual(annotations[2].type, .mat_peptide, "p17 should be enriched to .mat_peptide")
        XCTAssertEqual(annotations[3].type, .cds, "vpu should be enriched to .cds")
        XCTAssertEqual(enrichedCount, 3, "Three annotations should have been enriched")
    }

    /// queryByRegion only returns records that overlap the query region.
    func testEnrichmentOnlyAffectsAnnotationsInQueryRegion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrichment_region_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bedContent = [
            "chr1\t100\t500\tgeneA\t0\t+\t100\t500\t0,0,0\t1\t400\t0\tCDS\t",
            "chr1\t10000\t15000\tgeneB\t0\t+\t10000\t15000\t0,0,0\t1\t5000\t0\tmat_peptide\t",
        ].joined(separator: "\n")

        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try bedContent.write(to: bedURL, atomically: true, encoding: .utf8)
        let dbURL = tempDir.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let db = try AnnotationDatabase(url: dbURL)

        // Query only the first region [0, 1000)
        let dbRecords = db.queryByRegion(chromosome: "chr1", start: 0, end: 1000)

        var typeLookup: [String: String] = [:]
        for record in dbRecords {
            typeLookup["\(record.name)|\(record.start)|\(record.end)"] = record.type
        }

        // Only geneA should be in the lookup
        XCTAssertEqual(typeLookup.count, 1)
        XCTAssertEqual(typeLookup["geneA|100|500"], "CDS")
        XCTAssertNil(typeLookup["geneB|10000|15000"])
    }

    // MARK: - Helpers

    private func makeAnnotation(
        name: String,
        start: Int,
        end: Int,
        type: AnnotationType,
        color: AnnotationColor? = nil
    ) -> SequenceAnnotation {
        SequenceAnnotation(
            type: type,
            name: name,
            chromosome: "NC_001802.1",
            intervals: [AnnotationInterval(start: start, end: end)],
            strand: .forward,
            qualifiers: [:],
            color: color
        )
    }
}
