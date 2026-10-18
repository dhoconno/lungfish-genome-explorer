// CLIBlastSubmitRunnerTests.swift - The argv the BLAST runner hands `blast submit`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp

/// Phase 2.11 lane A65 M1. The runner names the query by path, never as text (SWIFT 6), passes each
/// lineage value as an option of its own only when the viewer has it, and asks for events.
final class CLIBlastSubmitRunnerTests: XCTestCase {
    func testTheArgvNamesTheQueryByPathAndEachLineageValue() {
        let request = BlastSubmitRequest(
            queryURL: URL(fileURLWithPath: "/p/.tmp/blast-query.fasta"),
            outputURL: URL(fileURLWithPath: "/p/naomgs-1/blast-verifications/run-1"),
            label: "Influenza A virus",
            taxId: 11320,
            sourceResultURL: URL(fileURLWithPath: "/p/naomgs-1"),
            sample: "S1",
            subsampleCount: 20,
            entrezQuery: "txid11320[Organism:exp]",
            acceptedTaxIds: [114727, 11320]
        )
        XCTAssertEqual(CLIBlastSubmitRunner.arguments(for: request), [
            "blast", "submit", "--query", "/p/.tmp/blast-query.fasta",
            "--output", "/p/naomgs-1/blast-verifications/run-1", "--name", "Influenza A virus",
            "--taxid", "11320", "--source-result", "/p/naomgs-1", "--sample", "S1", "--subsample-count", "20",
            "--entrez-query", "txid11320[Organism:exp]", "--accepted-taxid", "11320", "--accepted-taxid", "114727",
            "--format", "json", "--no-progress",
        ])
    }

    func testAContigWithNoTaxonPassesOnlyWhatItHas() {
        let request = BlastSubmitRequest(
            queryURL: URL(fileURLWithPath: "/q.fasta"), outputURL: URL(fileURLWithPath: "/o"), label: "contig_7",
            contig: "contig_7"
        )
        XCTAssertEqual(CLIBlastSubmitRunner.arguments(for: request), [
            "blast", "submit", "--query", "/q.fasta", "--output", "/o", "--name", "contig_7",
            "--contig", "contig_7", "--format", "json", "--no-progress",
        ])
    }

    func testADatabaseIsSentOnlyWhenTheRequestNamesOne() {
        var request = BlastSubmitRequest(
            queryURL: URL(fileURLWithPath: "/q.fasta"), outputURL: URL(fileURLWithPath: "/o"), label: "taxon"
        )
        XCTAssertFalse(
            CLIBlastSubmitRunner.arguments(for: request).contains("--database"),
            "no database, no flag, so the leaf searches its default core_nt (BIO 3)"
        )
        request.database = "nt"
        XCTAssertEqual(CLIBlastSubmitRunner.arguments(for: request), [
            "blast", "submit", "--query", "/q.fasta", "--output", "/o", "--name", "taxon",
            "--database", "nt", "--format", "json", "--no-progress",
        ])
    }

    func testCancelReturnsAtOnceWithNothingRunning() {
        let started = ContinuousClock.now
        CLIBlastSubmitRunner(cliURLOverride: URL(fileURLWithPath: "/nonexistent/lungfish-cli")).cancel()
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }
}
