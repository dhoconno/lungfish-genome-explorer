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
