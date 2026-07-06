// NaoMgsCommandTests.swift - NAO-MGS CLI behavior and provenance coverage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO
import LungfishWorkflow

final class NaoMgsCommandTests: XCTestCase {

    func testStandaloneImportWritesFilteredSummaryAndProvenance() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("naomgs-cli-\(UUID().uuidString)", isDirectory: true)
        let outputDir = tempDir.appendingPathComponent("summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputURL = tempDir.appendingPathComponent("virus_hits_final.tsv")
        try Self.naoMgsFixture.write(to: inputURL, atomically: true, encoding: .utf8)

        let command = try NaoMgsCommand.ImportSubcommand.parse([
            inputURL.path,
            "--sample-name", "S1",
            "--output-dir", outputDir.path,
            "--min-bitscore", "80",
            "--quiet",
        ])

        try await command.run()

        let outputURL = outputDir.appendingPathComponent("S1_nao-mgs_summary.json")
        let summaries = try JSONDecoder().decode(
            [NaoMgsTaxonSummary].self,
            from: Data(contentsOf: outputURL)
        )
        XCTAssertEqual(summaries.map(\.taxId), [111])
        XCTAssertEqual(summaries.first?.hitCount, 1)

        let directoryEnvelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: outputDir))
        XCTAssertEqual(directoryEnvelope.workflowName, "lungfish nao-mgs import")
        XCTAssertEqual(directoryEnvelope.argv, [
            "lungfish-cli", "nao-mgs", "import", inputURL.path,
            "--sample-name", "S1",
            "--output-dir", outputDir.path,
            "--min-bitscore", "80.0",
            "--quiet",
        ])
        XCTAssertEqual(directoryEnvelope.options.resolvedDefaults["originalHitCount"]?.integerValue, 2)
        XCTAssertEqual(directoryEnvelope.options.resolvedDefaults["filteredHitCount"]?.integerValue, 1)
        XCTAssertEqual(directoryEnvelope.options.resolvedDefaults["originalTaxonCount"]?.integerValue, 2)
        XCTAssertEqual(directoryEnvelope.options.resolvedDefaults["filteredTaxonCount"]?.integerValue, 1)
        XCTAssertNotNil(directoryEnvelope.runtimeIdentity)

        let fileEnvelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(fileEnvelope.output?.path, outputURL.path)
        XCTAssertNotNil(fileEnvelope.output?.checksumSHA256)
        XCTAssertEqual(fileEnvelope.output?.fileSize, UInt64(try Data(contentsOf: outputURL).count))
    }

    private static let naoMgsFixture = """
    sample\tseq_id\ttaxid\tbest_alignment_score\tcigar\tquery_start\tquery_end\tref_start\tref_end\tread_sequence\tread_quality\tsseqid\tstitle\tbitscore\tevalue\tpident
    S1\tread-1\t111\t90\t10M\t0\t10\t100\t110\tACGTACGTAA\tIIIIIIIIII\tNC_000001.1\tIncluded virus\t90\t1e-20\t99.0
    S1\tread-2\t222\t40\t10M\t0\t10\t200\t210\tTGCATGCATT\tIIIIIIIIII\tNC_000002.1\tFiltered virus\t40\t1e-5\t95.0
    """
}
