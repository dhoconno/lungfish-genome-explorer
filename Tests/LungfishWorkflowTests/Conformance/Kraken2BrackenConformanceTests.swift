// Kraken2BrackenConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// End-to-end conformance: runs the real kraken2 and bracken binaries against
// the shared SARS-CoV-2 fixture and the installed Kraken2 Viral database, then
// verifies the output through the app's real report/output parsers. By
// default a missing tool or database is a skip (dev machines drift); with
// LUNGFISH_REQUIRE_TOOLS=1 both become hard failures.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishIO

final class Kraken2BrackenConformanceTests: XCTestCase {
    func testClassifyFixtureReadsAgainstViralDB() async throws {
        let kraken2 = try await ToolAvailability.require("kraken2", environment: "kraken2")
        let bracken = try await ToolAvailability.require("bracken", environment: "bracken")
        let db = try await ToolAvailability.requireDatabase({ try await ConformanceFixtures.viralKrakenDB() }, name: "Kraken2 Viral")
        let tmp = try ConformanceFixtures.tempDir("kraken2")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r1 = ConformanceFixtures.sarscov2.appendingPathComponent("test_1.fastq.gz")
        let r2 = ConformanceFixtures.sarscov2.appendingPathComponent("test_2.fastq.gz")
        let kreport = tmp.appendingPathComponent("reads.kreport")
        let kout = tmp.appendingPathComponent("reads.kraken")

        let res = try ProcessRunner.run(
            kraken2,
            ["--db", db.path, "--paired", "--gzip-compressed", "--report", kreport.path, "--output", kout.path, r1.path, r2.path],
            timeout: 900
        )
        XCTAssertEqual(res.status, 0, res.stderr)

        let tree = try KreportParser.parse(url: kreport)
        XCTAssertGreaterThan(tree.totalReads, 0)
        // This viral-only fixture classifies 100% of reads against the Viral
        // DB, so there is no unclassified (U) line in the kreport at all --
        // `unclassifiedNode` is legitimately nil here. Assert root presence
        // and (when present) that the unclassified node is well-formed,
        // rather than requiring one to exist.
        XCTAssertEqual(tree.root.rank, .root, "kreport should have a root (R) node")
        if let unclassified = tree.unclassifiedNode {
            XCTAssertEqual(unclassified.rank, .unclassified)
        }
        XCTAssertNotNil(
            findNode(tree.root) { $0.name.localizedCaseInsensitiveContains("Severe acute respiratory syndrome") },
            "SARS-CoV-2 must be detected in the kreport"
        )

        let outputs = try Kraken2OutputParser.parse(url: kout)
        XCTAssertGreaterThan(outputs.count, 0)
        XCTAssertGreaterThan(
            outputs.filter { $0.isClassified }.count,
            outputs.count / 2,
            "most fixture reads should classify"
        )

        let bout = tmp.appendingPathComponent("reads.bracken")
        let bres = try ProcessRunner.run(
            bracken,
            ["-d", db.path, "-i", kreport.path, "-o", bout.path, "-r", "150", "-l", "S"],
            timeout: 300
        )
        XCTAssertEqual(bres.status, 0, bres.stderr)

        let brackenRows = try BrackenParser.parse(url: bout)
        XCTAssertNotNil(
            brackenRows.first { $0.name.localizedCaseInsensitiveContains("Severe acute respiratory syndrome") },
            "Bracken should report an abundance row for SARS-CoV-2"
        )
    }

    /// Depth-first search for a node satisfying `predicate` in a `TaxonTree`'s
    /// hierarchy, rooted at `node`.
    private func findNode(_ node: TaxonNode, where predicate: (TaxonNode) -> Bool) -> TaxonNode? {
        if predicate(node) { return node }
        for child in node.children {
            if let found = findNode(child, where: predicate) {
                return found
            }
        }
        return nil
    }
}
