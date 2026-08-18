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
        // Either name is accepted, for the taxonomy rename described at the
        // Bracken assertion below: the 20260626 index reports the species as
        // "Betacoronavirus pandemicum", keeping the old SARS-CoV-2 name on its S1
        // child. The kreport does still carry both, but relying on that would put
        // this assertion one taxonomy revision away from silently passing on a
        // name that no longer identifies the lineage.
        XCTAssertNotNil(
            findNode(tree.root) {
                $0.name.localizedCaseInsensitiveContains("Severe acute respiratory syndrome")
                    || $0.name.localizedCaseInsensitiveContains("Betacoronavirus pandemicum")
            },
            "SARS-CoV-2 must be detected in the kreport"
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
        let brackenArgs = BrackenInvocation.arguments(
            dialect: dialect,
            databasePath: db,
            distributionURL: distribution.url,
            reportURL: kreport,
            outputURL: bout,
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

        let brackenRows = try BrackenParser.parse(url: bout)
        // Matched on taxonomy id, not on the scientific name.
        //
        // Bracken aggregates at level S, and which taxon that lands on depends on
        // which taxonomy the installed index was built against. The 20240904 index
        // rolls the fixture up to "Severe acute respiratory syndrome-related
        // coronavirus" (694009); the 20260626 index reports "Betacoronavirus
        // pandemicum" (3418604), NCBI's rename of the species covering SARS-CoV-2,
        // with "Severe acute respiratory syndrome coronavirus 2" (2697049) demoted
        // to the S1 rank beneath it.
        //
        // The previous form matched the substring "Severe acute respiratory
        // syndrome", which happened to cover both pre-rename names and silently
        // stopped matching anything at all under the new index, even though
        // classification was perfect (all 100 fixture reads land on the species
        // row). Ids are the stable handle across a taxonomy revision.
        let sarsCoV2SpeciesIDs: Set<Int> = [
            694009,   // Severe acute respiratory syndrome-related coronavirus (20240904 index)
            2697049,  // Severe acute respiratory syndrome coronavirus 2 (pre-rename species, now S1)
            3418604,  // Betacoronavirus pandemicum (species as of the 20260626 index)
        ]
        let sarsRow = brackenRows.first { sarsCoV2SpeciesIDs.contains($0.taxId) }
        XCTAssertNotNil(
            sarsRow,
            "Bracken should report an abundance row for SARS-CoV-2 (taxid 2697049 or 3418604); "
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
            readLength: 150,
            levelCode: "S",
            threshold: 10
        )
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
