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

    /// Taxonomy ids that identify the SARS-CoV-2 lineage in a Kraken2 Viral index,
    /// across the taxonomy revisions the shipped indexes are built against.
    ///
    /// Matching is by id rather than by scientific name because the name is not
    /// stable. In the 20240904 index the fixture rolls up to "Severe acute
    /// respiratory syndrome-related coronavirus" (694009). The 20260626 index
    /// carries NCBI's rename of the species to "Betacoronavirus pandemicum"
    /// (3418604), demoting "Severe acute respiratory syndrome coronavirus 2"
    /// (2697049) to the S1 rank beneath it.
    ///
    /// A substring match on "Severe acute respiratory syndrome" happened to cover
    /// both pre-rename names and then matched nothing at all under the new index,
    /// even though classification was perfect: all 100 fixture reads land on the
    /// species row. Ids are the stable handle across a taxonomy revision.
    private static let sarsCoV2TaxIDs: Set<Int> = [
        694009,   // Severe acute respiratory syndrome-related coronavirus (20240904 index)
        2697049,  // Severe acute respiratory syndrome coronavirus 2 (pre-rename species, now S1)
        3418604,  // Betacoronavirus pandemicum (species as of the 20260626 index)
    ]

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
        // Matched on taxonomy id, for the reason given at `sarsCoV2TaxIDs`.
        XCTAssertNotNil(
            findNode(tree.root) { Self.sarsCoV2TaxIDs.contains($0.taxId) },
            "SARS-CoV-2 must be detected in the kreport (taxid one of \(Self.sarsCoV2TaxIDs.sorted()))"
        )

        let outputs = try Kraken2OutputParser.parse(url: kout)
        XCTAssertGreaterThan(outputs.count, 0)
        XCTAssertGreaterThan(
            outputs.filter { $0.isClassified }.count,
            outputs.count / 2,
            "most fixture reads should classify"
        )

        // Bracken is invoked through the production decision path rather than a
        // hand-written argv, so this test fails if the shipped app would build
        // arguments the installed Bracken build rejects. The arm64 bioconda
        // build (`bracken=1.0.0`) exposes only the inner `est_abundance.py`
        // CLI, which has no `-d`; a real 2.x/3.x driver takes `-d`.
        let dialect = await ClassificationPipeline.shared.detectBrackenDialect(environment: "bracken")
        let distribution = try BrackenInvocation.resolveKmerDistribution(
            databasePath: db,
            readLength: 150,
            availableFilenames: BrackenInvocation.availableDistributionFilenames(inDatabase: db)
        )
        let bout = tmp.appendingPathComponent("reads.bracken")
        let breport = tmp.appendingPathComponent("reads.bracken.kreport")
        let brackenArgs = BrackenInvocation.arguments(
            dialect: dialect,
            databasePath: db,
            distributionURL: distribution.url,
            reportURL: kreport,
            outputURL: bout,
            reportOutputURL: breport,
            readLength: 150,
            levelCode: "S",
            threshold: 10
        )
        let bres = try ProcessRunner.run(bracken, brackenArgs, timeout: 300)

        // `bracken=1.0.0` writes the complete abundance table and *then* crashes
        // with an UnboundLocalError on `u_reads` when the Kraken report has no
        // unclassified line -- which this 100%-classified viral fixture never
        // has. The pipeline tolerates exactly that signature, so the test does
        // too; any other non-zero exit is a real failure.
        if bres.status != 0 {
            XCTAssertTrue(
                dialect == .kmerDistribution
                    && BrackenInvocation.isUnclassifiedReadsCrash(stderr: bres.stderr),
                "bracken exited \(bres.status) with an unexpected error: \(bres.stderr)"
            )
        }

        // `-w` must be honoured by the installed CLI: without it Bracken
        // auto-names the re-estimated report and nothing can declare the path.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: breport.path),
            "the installed Bracken must write its re-estimated report to the -w path"
        )

        let brackenRows = try BrackenParser.parse(url: bout)
        // Matched on taxonomy id, for the reason given at `sarsCoV2TaxIDs`. Bracken
        // aggregates at level S, so which of those ids appears depends on the
        // taxonomy the installed index was built against.
        let sarsRow = brackenRows.first { Self.sarsCoV2TaxIDs.contains($0.taxId) }
        XCTAssertNotNil(
            sarsRow,
            "Bracken should report an abundance row for SARS-CoV-2 "
            + "(taxid one of \(Self.sarsCoV2TaxIDs.sorted())); "
            + "got: \(brackenRows.map { "\($0.name) [\($0.taxId)]" })"
        )
        XCTAssertGreaterThan(sarsRow?.newEstReads ?? 0, 0)
    }

    /// The arguments the pipeline builds must match the CLI the installed
    /// Bracken actually advertises: `-d` only for the real driver, `-k` for the
    /// `est_abundance.py` passthrough.
    func testProductionArgumentsMatchInstalledBrackenCLI() async throws {
        let bracken = try await ToolAvailability.require("bracken", environment: "bracken")
        let help = try ProcessRunner.run(bracken, ["--help"], timeout: 60)
        let dialect = BrackenInvocation.dialect(fromHelpText: help.stdout + help.stderr)
        let pipelineDialect = await ClassificationPipeline.shared.detectBrackenDialect(environment: "bracken")
        XCTAssertEqual(
            dialect,
            pipelineDialect,
            "the pipeline's cached detection must agree with a direct probe"
        )

        let args = BrackenInvocation.arguments(
            dialect: dialect,
            databasePath: URL(fileURLWithPath: "/db"),
            distributionURL: URL(fileURLWithPath: "/db/database150mers.kmer_distrib"),
            reportURL: URL(fileURLWithPath: "/out/r.kreport"),
            outputURL: URL(fileURLWithPath: "/out/r.bracken"),
            reportOutputURL: URL(fileURLWithPath: "/out/r.bracken.kreport"),
            readLength: 150,
            levelCode: "S",
            threshold: 10
        )
        XCTAssertTrue(args.contains("-w"), "both dialects accept -w for the re-estimated report")
        switch dialect {
        case .database:
            XCTAssertTrue(args.contains("-d"))
        case .kmerDistribution:
            XCTAssertTrue(args.contains("-k"))
            XCTAssertFalse(args.contains("-d"), "est_abundance.py rejects -d")
        }
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
