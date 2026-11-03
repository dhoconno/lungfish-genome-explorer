// ClassifierBlastOperationRowWordsTests.swift - A finished BLAST row counts support, not alignment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN, item 2 (BLAST-VERIFIED-WORD). "N/M verified" counted alignment quality, so a read whose best
// match is another organism read as verified on the Operations row while the pane said contradicting. Kraken2's row
// already says the pane's counts. The stand-in leaf writes the record the viewer's own query names, so the run goes the
// whole route to the row's last words, and nothing leaves the Mac.

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp

@MainActor
final class ClassifierBlastOperationRowWordsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "blast-row-words")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    func testClassifierOperationRowCountsSupportNotAlignment() async throws {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/classifier-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let bam = result.appendingPathComponent("sample.bam")
        let leaf = try leafReportingOneContradictingRead()
        let drawer = BlastSubmitDrawer(loading: { _ in }, results: { _, _ in }, failure: { _ in })
        let reads = (1...4).map { (id: "read_\($0)", sequence: String(repeating: "ACGT", count: $0 + 2)) }
        let viewer = ViewerViewController()

        let taxTriageName = "Influenza A virus (row words, TaxTriage)"
        await viewer.launchTaxTriageBlastSubmit(
            organism: TaxTriageOrganism(name: taxTriageName, score: 0.9, reads: 100, coverage: 50, taxId: 11320, rank: "species", sample: "S1"),
            readCount: 2, accessions: ["NC_026438.1"], bamURL: bam, bamIndexURL: nil,
            resultURL: result, controller: nil, drawer: drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: leaf), extractReads: { _, _, _, _ in reads }
        )?.value
        try await assertRowCountsSupport(titled: "BLAST \(taxTriageName)")

        let esVirituName = "Influenza A virus (row words, EsViritu)"
        await viewer.launchEsVirituBlastSubmit(
            detection: BlastSubmitParity.esVirituDetection(name: esVirituName, species: "Alphainfluenzavirus influenzae", genus: "Alphainfluenzavirus"),
            readCount: 2, accessions: ["NC_026433.1"], bamURL: bam, bamIndexURL: nil,
            resultURL: result, controller: nil, drawer: drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: leaf), extractReads: { _, _, _, _ in reads },
            taxonomyContext: { _ in BlastTaxonomyContext(cladeTaxIds: [2955291], cladeNames: ["Influenza A virus"]) }
        )?.value
        try await assertRowCountsSupport(titled: "BLAST \(esVirituName)")
    }

    private func assertRowCountsSupport(titled title: String) async throws {
        let finished = await LungfishTestSupport.waitUntil {
            OperationCenter.shared.items.first { $0.title == title }?.state == .completed
        }
        XCTAssertTrue(finished, "the row \(title) completes")
        let item = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == title })
        defer { OperationCenter.shared.clearItem(id: item.id) }
        XCTAssertEqual(item.detail, "0 supporting, 1 contradicting of 1 read")
    }

    /// A shell script in place of `lungfish-cli`. It fills the digest of the query it is handed into a saved record of
    /// one `.verified` read whose best match is another organism, then names the record in its `complete` event.
    private func leafReportingOneContradictingRead() throws -> URL {
        let read = try JSONDecoder().decode(BlastReadResult.self, from: Data(
            #"{"hasLCADisagreement":false,"id":"read_1","matchesQueriedTaxon":false,"querySequence":"ACGT","topHits":[],"verdict":"verified"}"#.utf8
        ))
        let completedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let record = BlastSubmissionRecord(
            savedAt: completedAt,
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: "DIGESTPLACEHOLDER", sequenceCount: 2),
            lineage: .init(),
            search: .init(BlastVerificationRequest(
                taxonName: "Influenza A virus", taxId: 11320, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
            )),
            result: BlastVerificationResult(
                taxonName: "Influenza A virus", taxId: 11320, totalReads: 1, verifiedCount: 1, ambiguousCount: 0,
                unverifiedCount: 0, errorCount: 0, readResults: [read], submittedAt: completedAt,
                completedAt: completedAt, rid: "STANDIN1", blastProgram: "blastn", database: "core_nt"
            )
        )
        let template = folder.appendingPathComponent("record-template.json")
        try BlastSubmissionRecord.encoder.encode(record).write(to: template)
        let output = folder.appendingPathComponent(BlastSubmissionRecord.recordFileName)
        let complete = #"{"event":"complete","message":"rid=STANDIN1","output":"\#(output.path)","outputs":["\#(output.path)"],"progress":1,"schemaVersion":2}"#
        let script = """
        #!/bin/sh
        for argument in "$@"; do
          case "$argument" in */\(BlastSubmissionRecord.queryFileName)) query="$argument" ;; esac
        done
        digest=$(/usr/bin/shasum -a 256 "$query" | /usr/bin/cut -d ' ' -f 1)
        /usr/bin/sed "s/DIGESTPLACEHOLDER/$digest/" '\(template.path)' > '\(output.path)'
        /bin/echo '\(complete)'

        """
        let url = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
