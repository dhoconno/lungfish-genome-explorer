// GFF3RealFileTest.swift - Test with actual GFF3 file
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GFF3RealFileTest: XCTestCase {
    
    let testFilePath = "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_annotations.gff3"
    
    func testReadRealFile() async throws {
        let url = URL(fileURLWithPath: testFilePath)
        
        // Skip if file doesn't exist
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test file not available")
        }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        // Should have 59 features
        XCTAssertEqual(features.count, 59, "Expected 59 features")
        
        // Test feature types
        let types = Set(features.map { $0.type })
        XCTAssertTrue(types.contains("gene"))
        XCTAssertTrue(types.contains("mRNA"))
        XCTAssertTrue(types.contains("exon"))
        XCTAssertTrue(types.contains("CDS"))
        
        // Test strand parsing
        let forwardCount = features.filter { $0.strand == .forward }.count
        let reverseCount = features.filter { $0.strand == .reverse }.count
        let unknownCount = features.filter { $0.strand == .unknown }.count
        
        XCTAssertEqual(forwardCount, 37, "Expected 37 forward strand features")
        XCTAssertEqual(reverseCount, 15, "Expected 15 reverse strand features")
        XCTAssertEqual(unknownCount, 7, "Expected 7 unknown strand features")
        
        // Test parent-child relationships
        let withParent = features.filter { $0.parentID != nil }
        XCTAssertEqual(withParent.count, 43, "Expected 43 features with Parent attribute")
        
        // Verify all parents exist
        let ids = Set(features.compactMap { $0.attributes["ID"] })
        for feature in withParent {
            if let parent = feature.parentID {
                XCTAssertTrue(ids.contains(parent), "Parent \(parent) not found")
            }
        }
    }
    
    func testSequenceDistribution() async throws {
        let url = URL(fileURLWithPath: testFilePath)
        
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test file not available")
        }
        
        let reader = GFF3Reader()
        let grouped = try await reader.readGroupedBySequence(from: url)
        
        XCTAssertEqual(grouped.count, 4, "Expected 4 sequences")
        XCTAssertEqual(grouped["TestSequence1"]?.count, 18)
        XCTAssertEqual(grouped["Chromosome1"]?.count, 8)
        XCTAssertEqual(grouped["Chromosome2"]?.count, 8)
        XCTAssertEqual(grouped["LargeChromosome1"]?.count, 25)
    }
    
    func testConvertToAnnotations() async throws {
        let url = URL(fileURLWithPath: testFilePath)
        
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test file not available")
        }
        
        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: url)
        
        XCTAssertEqual(annotations.count, 59)
        
        // Check type mapping
        let genes = annotations.filter { $0.type == .gene }
        XCTAssertEqual(genes.count, 7)
        
        let cds = annotations.filter { $0.type == .cds }
        XCTAssertEqual(cds.count, 15)
        
        let exons = annotations.filter { $0.type == .exon }
        XCTAssertEqual(exons.count, 18)
        
        // Check chromosome assignment
        for annotation in annotations {
            XCTAssertNotNil(annotation.chromosome, "Annotation should have chromosome set")
        }
    }
    
    func testCoordinateConversion() async throws {
        let url = URL(fileURLWithPath: testFilePath)
        
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test file not available")
        }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        let annotations = try await reader.readAsAnnotations(from: url)
        
        // Get first gene feature
        let geneFeature = features.first { $0.type == "gene" }
        let geneAnnot = annotations.first { $0.type == .gene }
        
        XCTAssertNotNil(geneFeature)
        XCTAssertNotNil(geneAnnot)
        
        if let feature = geneFeature, let annot = geneAnnot {
            // GFF3 is 1-based, inclusive
            // Annotation should be 0-based with start converted
            XCTAssertEqual(annot.start, feature.start - 1, "Start should be converted to 0-based")
            XCTAssertEqual(annot.end, feature.end, "End should remain the same for 0-based exclusive")
        }
    }
    
    func testCDSPhaseHandling() async throws {
        let url = URL(fileURLWithPath: testFilePath)
        
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test file not available")
        }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        let cdsFeatures = features.filter { $0.type == "CDS" }
        
        // All CDS in test file have phase 0
        for cds in cdsFeatures {
            XCTAssertEqual(cds.phase, 0, "CDS phase should be 0")
        }
    }
    
    func testBothStrandsHandled() async throws {
        let url = URL(fileURLWithPath: testFilePath)
        
        guard FileManager.default.fileExists(atPath: testFilePath) else {
            throw XCTSkip("Test file not available")
        }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        // Find genes on different strands
        let forwardGenes = features.filter { $0.type == "gene" && $0.strand == .forward }
        let reverseGenes = features.filter { $0.type == "gene" && $0.strand == .reverse }
        
        XCTAssertGreaterThan(forwardGenes.count, 0, "Should have forward strand genes")
        XCTAssertGreaterThan(reverseGenes.count, 0, "Should have reverse strand genes")
        
        // Verify specific genes
        let testGeneA = features.first { $0.attributes["Name"] == "testGeneA" }
        XCTAssertEqual(testGeneA?.strand, .forward)
        
        let testGeneB = features.first { $0.attributes["Name"] == "testGeneB" }
        XCTAssertEqual(testGeneB?.strand, .reverse)
    }
}
