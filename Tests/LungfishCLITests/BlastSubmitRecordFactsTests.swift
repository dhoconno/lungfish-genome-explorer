// BlastSubmitRecordFactsTests.swift - Two facts of the `blast submit` record, the portable lineage and the failed record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.08, BIO 6 and BIO 4 of the 2.11 A65 review. The record names the result its sequences came
// from as `@/<path in the project>` through `PortablePath`, so the lineage survives a project move and names no
// account. A search that fails leaves a `failed` record beside the query copy, so a person sees why the folder
// holds no result. A record written before 2.12, with an absolute source path, still loads.

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

final class BlastSubmitRecordFactsTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-submit-facts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// BIO 6. A record in a project names a source result in that project as a project path.
    func testTheRecordNamesASourceResultInItsProjectAsAProjectPath() async throws {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let source = project.appendingPathComponent("Analyses/nvd-run", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let output = project.appendingPathComponent("blast-verifications/nvd-search", isDirectory: true)
        let command = try XCTUnwrap(BlastCommand.parseAsRoot([
            "submit", "--query", try writeQuery().path, "--output", output.path, "--source-result", source.path,
            "--sample", "S1", "--contig", "NODE_1",
        ]) as? BlastCommand.SubmitSubcommand)

        let staged = try command.stageQuery(into: output)
        let request = command.makeRequest(sequences: staged.sequences)
        let result = try await BlastSubmitCommandTests.cannedResult(for: request)
        let recordURL = try command.writeRecord(result: result, request: request, query: staged, in: output, runClock: ProvenanceRunClock())

        let record = try BlastSubmissionRecord.load(recordURL)
        XCTAssertEqual(record.lineage.sourceResult, "@/Analyses/nvd-run", "the lineage is a path in the project")
        XCTAssertEqual(record.lineage.sample, "S1", "the rest of the lineage is as given")
        XCTAssertEqual(record.lineage.contig, "NODE_1")
        XCTAssertEqual(
            record.lineage.sourceResultURL(recordAt: recordURL)?.standardizedFileURL.path, source.standardizedFileURL.path,
            "the project path reads back as the folder"
        )
    }

    /// A record written before 2.12 holds its source result as an absolute path. It still loads, and the path
    /// reads as written.
    func testAnOlderRecordWithAnAbsoluteSourceResultStillLoads() async throws {
        let output = scratch.appendingPathComponent("Project.lungfish/blast-verifications/older", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let absolute = "/Users/someone/Older.lungfish/Analyses/naomgs-run"
        let request = BlastVerificationRequest(taxonName: "Influenza A virus", taxId: 11320, sequences: [(id: "read_1", sequence: "ACGT")])
        let older = BlastSubmissionRecord(
            savedAt: Date(timeIntervalSince1970: 1_790_000_000),
            query: .init(fileName: "query.fasta", sha256: String(repeating: "0", count: 64), sequenceCount: 1),
            lineage: .init(sourceResult: absolute, sample: "S1", taxId: 11320),
            search: .init(request),
            result: try await BlastSubmitCommandTests.cannedResult(for: request)
        )
        let recordURL = output.appendingPathComponent("blast-result.json")
        try BlastSubmissionRecord.encoder.encode(older).write(to: recordURL)

        let loaded = try BlastSubmissionRecord.load(recordURL)
        XCTAssertEqual(loaded.lineage, older.lineage, "the older lineage loads unchanged")
        XCTAssertEqual(loaded.lineage.sourceResultURL(recordAt: recordURL)?.path, absolute, "an absolute path reads as written")
        XCTAssertNil(BlastSubmissionRecord.Lineage(sample: "S1").sourceResultURL(recordAt: recordURL))
    }

    /// BIO 4. A search NCBI fails exits 1 with a `failed` event, keeps the query copy, writes no result and
    /// leaves one record beside the copy whose status is `failed` and whose standard error holds the reason.
    func testAFailedSearchLeavesAFailedRecordBesideTheQueryCopy() async throws {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        let server = try LoopbackHTTPStandIn.start { request in
            guard request.path == "/blast/Blast.cgi" else { return .notFound }
            if request.method == "POST" {
                return .text("<!--QBlastInfoBegin\n    RID = STANDIN1\n    RTOE = 1\nQBlastInfoEnd-->")
            }
            return .text("<!--QBlastInfoBegin\n    Status=FAILED\nQBlastInfoEnd-->")
        }
        defer { server.stop() }
        let output = scratch.appendingPathComponent("failed", isDirectory: true)
        let result = try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli,
            arguments: ["blast", "submit", "--query", try writeQuery().path, "--output", output.path, "--format", "json"],
            environment: CLISIGTERMHarness.childEnvironment(
                overriding: ["LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString]),
            timeout: .seconds(90)
        ))

        XCTAssertEqual(result.status, 1, result.stderrText)
        XCTAssertTrue(result.stdoutText.contains(#""event":"failed""#), result.stdoutText)
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(atPath: output.appendingPathComponent("query.fasta").path))
        XCTAssertFalse(fileManager.fileExists(atPath: output.appendingPathComponent("blast-result.json").path))
        let names = ((try? fileManager.contentsOfDirectory(atPath: output.path)) ?? [])
            .filter { $0.hasPrefix("lungfish-blast-submit-") && $0.hasSuffix(".lungfish-provenance.json") }
        XCTAssertEqual(names.count, 1, "one failed record beside the query copy, found \(names)")
        let recordURL = output.appendingPathComponent(names.first ?? "none")
        let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: recordURL)
        XCTAssertEqual(envelope?.status.rawValue, "failed")
        let text = (try? String(contentsOf: recordURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("BLAST search failed"), "the record says why: \(text.prefix(400))")
    }

    // MARK: - Fixtures

    private func writeQuery() throws -> URL {
        let url = scratch.appendingPathComponent("query-from-viewer.fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: url)
        return url
    }
}
