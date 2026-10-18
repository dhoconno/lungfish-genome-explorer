// MappingResultTests.swift - mapping-result.json schema 1 and 2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// A schema-1 `mapping-result.json` lists every reference sequence, zero rows
/// included, and still loads, shows and saves exactly as before (BIO 1).
final class MappingResultTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-result")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testSchemaOneResultWithZeroReadRowsLoads() throws {
        let sidecar = root.appendingPathComponent("mapping-result.json")
        try Data(Self.schemaOneJSON.utf8).write(to: sidecar)

        let result = try MappingResult.load(from: root)

        XCTAssertEqual(result.contigs.map(\.contigName), ["MT192765.1", "unaligned-a", "unaligned-b"])
        XCTAssertEqual(result.contigs.map(\.mappedReads), [197, 0, 0])
        XCTAssertEqual(result.contigs.map(\.contigLength), [29_829, 1_500, 800])
        XCTAssertEqual(result.contigs[0].meanIdentity, 0.9948906974198022)
        XCTAssertEqual(result.totalReads, 200)
        XCTAssertEqual(result.bamURL, root.appendingPathComponent("sarscov2-test.sorted.bam").standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: sidecar), Data(Self.schemaOneJSON.utf8), "loading rewrites nothing")
        XCTAssertNil(result.referenceCount, "an absent count means unknown")
        XCTAssertNil(result.unalignedReferenceCount, "an absent count means unknown")
    }

    func testSchemaTwoRoundTripsCounts() throws {
        let result = makeResult(referenceCount: 5, unalignedReferenceCount: 3)

        try result.save(to: root)

        let object = try sidecarObject()
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual(object["referenceCount"] as? Int, 5)
        XCTAssertEqual(object["unalignedReferenceCount"] as? Int, 3)
        let loaded = try MappingResult.load(from: root)
        XCTAssertEqual(loaded.referenceCount, 5)
        XCTAssertEqual(loaded.unalignedReferenceCount, 3)
        XCTAssertEqual(loaded.contigs, result.contigs)
    }

    /// Schema 1 never holds a count, so a result that knows only one writes neither.
    func testOneCountAloneWritesSchemaOneWithNoCounts() throws {
        try makeResult(referenceCount: 5, unalignedReferenceCount: nil).save(to: root)

        let object = try sidecarObject()
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertNil(object["referenceCount"])
        XCTAssertNil(object["unalignedReferenceCount"])
    }

    /// A later build may write a higher schema with keys this one does not
    /// know. This build reads what it knows and never refuses the number.
    func testLoadAcceptsAHigherSchemaWithKeysItDoesNotKnow() throws {
        let later = Self.schemaOneJSON.replacingOccurrences(
            of: "\"schemaVersion\" : 1,",
            with: "\"laterKey\" : [1, 2], \"referenceCount\" : 9, \"schemaVersion\" : 3, \"unalignedReferenceCount\" : 6,"
        )
        try Data(later.utf8).write(to: root.appendingPathComponent("mapping-result.json"))

        let loaded = try MappingResult.load(from: root)

        XCTAssertEqual(loaded.contigs.count, 3)
        XCTAssertEqual(loaded.referenceCount, 9)
        XCTAssertEqual(loaded.unalignedReferenceCount, 6)
    }

    /// Publication saves the copy `withViewerBundle` makes, so the copy keeps
    /// both counts and the published result stays schema 2 (ARCH ruling Q-B1).
    func testWithViewerBundleKeepsCounts() throws {
        let result = makeResult(referenceCount: 5, unalignedReferenceCount: 3)

        let published = result.withViewerBundle(
            viewerBundleURL: root.appendingPathComponent("viewer.lungfishref", isDirectory: true),
            sourceReferenceBundleURL: nil
        )

        XCTAssertEqual(published.referenceCount, 5)
        XCTAssertEqual(published.unalignedReferenceCount, 3)
        try published.save(to: root)
        XCTAssertEqual(try sidecarObject()["schemaVersion"] as? Int, 2, "the published result is schema 2")
    }

    // MARK: - Helpers

    /// Two rows, one with primary reads and one with only a supplementary record.
    private func makeResult(referenceCount: Int?, unalignedReferenceCount: Int?) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: root.appendingPathComponent("sample.sorted.bam"),
            baiURL: root.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 197,
            unmappedReads: 3,
            wallClockSeconds: 1.5,
            contigs: [
                MappingContigSummary(
                    contigName: "MT192765.1", contigLength: 29_829, mappedReads: 197, mappedReadPercent: 98.5,
                    meanDepth: 0.9, coverageBreadth: 0.43, medianMAPQ: 60, meanIdentity: 0.99
                ),
                MappingContigSummary(
                    contigName: "supplementary-only", contigLength: 1_500, mappedReads: 0, mappedReadPercent: 0,
                    meanDepth: 0, coverageBreadth: 0, medianMAPQ: 40, meanIdentity: 0.95
                ),
            ],
            referenceCount: referenceCount,
            unalignedReferenceCount: unalignedReferenceCount
        )
    }

    private func sidecarObject() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("mapping-result.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// A result that records no reference counts saves the schema-1 bytes it
    /// always did.
    func testSchemaOneSaveWritesTheSameBytes() throws {
        let sidecar = root.appendingPathComponent("mapping-result.json")
        try Data(Self.schemaOneJSON.utf8).write(to: sidecar)
        let result = try MappingResult.load(from: root)

        try result.save(to: root)

        XCTAssertEqual(String(decoding: try Data(contentsOf: sidecar), as: UTF8.self), Self.schemaOneJSON)
    }

    // MARK: - Fixtures

    /// A schema-1 sidecar in the encoder's own format, with two references
    /// that have no alignments listed as zero rows.
    private static let schemaOneJSON = """
    {
      "baiPath" : "sarscov2-test.sorted.bam.bai",
      "bamPath" : "sarscov2-test.sorted.bam",
      "contigs" : [
        {
          "contigLength" : 29829,
          "contigName" : "MT192765.1",
          "coverageBreadth" : 0.430822,
          "mappedReadPercent" : 98.5,
          "mappedReads" : 197,
          "meanDepth" : 0.918603,
          "meanIdentity" : 0.9948906974198022,
          "medianMAPQ" : 60,
          "readGroupIDs" : [

          ]
        },
        {
          "contigLength" : 1500,
          "contigName" : "unaligned-a",
          "coverageBreadth" : 0,
          "mappedReadPercent" : 0,
          "mappedReads" : 0,
          "meanDepth" : 0,
          "meanIdentity" : 0,
          "medianMAPQ" : 0,
          "readGroupIDs" : [

          ]
        },
        {
          "contigLength" : 800,
          "contigName" : "unaligned-b",
          "coverageBreadth" : 0,
          "mappedReadPercent" : 0,
          "mappedReads" : 0,
          "meanDepth" : 0,
          "meanIdentity" : 0,
          "medianMAPQ" : 0,
          "readGroupIDs" : [

          ]
        }
      ],
      "mappedReads" : 197,
      "mapper" : "minimap2",
      "modeID" : "short-read-default",
      "schemaVersion" : 1,
      "totalReads" : 200,
      "unmappedReads" : 3,
      "wallClockSeconds" : 1.5
    }
    """
}
