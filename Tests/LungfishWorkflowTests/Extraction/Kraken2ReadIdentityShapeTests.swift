// Kraken2ReadIdentityShapeTests.swift - Extract keeps every real shape of a Kraken2 result and records its note
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane READ-IDENTITY, continuation. The read check must never refuse a valid result: an interleaved run
// without --paired names each mate on its own line, under one ID or with `/1` and `/2`. The note that the files
// changed but the reads did not reaches the extracted bundle's record, and a batch whose every sample was skipped
// for changed reads says so.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class Kraken2ReadIdentityShapeTests: XCTestCase {

    /// kraken2 without --paired on interleaved pairs whose headers end ` 1:N` and ` 2:N`: two lines under one ID.
    /// Mate 2 of r2 is unclassified, and Extract takes both mates of r1 and r2 by the fragment name.
    func testAnInterleavedRunWithoutPairedKeepsBothMatesOfOneID() async throws {
        let project = try makeProject(records: [
            ("r1 1:N:0:A", 20), ("r1 2:N:0:A", 18), ("r2 1:N:0:A", 20), ("r2 2:N:0:A", 18),
        ])
        try project.writeResult(lengths: [])
        try writeKrakenLines(["C\tr1\t562\t20", "C\tr1\t562\t18", "C\tr2\t562\t20", "U\tr2\t0\t18"], in: project)

        let outcome = try await extract(project)

        XCTAssertEqual(outcome.readCount, 4, "both mates of r1 and r2")
    }

    /// The same run with reads named `r1/1` and `r1/2`: each line names its mate.
    func testAnInterleavedRunWithoutPairedMatchesEachMateSuffix() async throws {
        let project = try makeProject(records: [("r1/1", 20), ("r1/2", 18), ("r2/1", 20), ("r2/2", 18)])
        try project.writeResult(lengths: [])
        try writeKrakenLines(["C\tr1/1\t562\t20", "C\tr1/2\t562\t18", "C\tr2/1\t562\t20", "C\tr2/2\t562\t18"], in: project)

        let outcome = try await extract(project)

        XCTAssertEqual(outcome.readCount, 4)
    }

    /// The reads imported again in another order (BIO-READ-IDENTITY 4.3): the note reaches the extracted bundle's
    /// record, from which its provenance step takes its parameters.
    func testTheNoteThatTheFilesChangedReachesTheExtractedBundlesRecord() async throws {
        let project = try makeProject(records: [("r1", 20), ("r2", 20), ("r3", 20), ("r4", 20)])
        let recordedSize = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: project.payload.path)[.size] as? UInt64)
        try project.writeResult(
            lengths: Array(repeating: "20", count: 4),
            identities: [ReadFileIdentity(url: project.payload, sizeBytes: recordedSize, sha256: nil)]
        )
        try project.replaceReads(["r4", "r3", "r2", "r1"].map { ($0, String(repeating: "A", count: 20)) }, comment: " again")

        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2, resultPath: project.resultFolder, selections: [ClassifierRowSelector(taxIds: [562])],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: project.project, displayName: "taxon",
                metadata: ExtractionMetadata(sourceDescription: "taxon", toolName: "Kraken2", parameters: ["taxIds": "562"])
            )
        )

        guard case .bundle(let bundleURL, let readCount) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(readCount, 4)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            ExtractionMetadata.self, from: Data(contentsOf: bundleURL.appendingPathComponent("extraction-metadata.json"))
        )
        XCTAssertEqual(
            metadata.parameters["classifierExtractionReadsChangedNote"],
            "The reads at Imports/s.lungfishfastq changed after this result was made. Every read it names is there "
                + "with the length kraken2 saw, so Lungfish extracted them."
        )
    }

    /// A batch whose every selected sample has reads one base shorter than kraken2 saw: the error says the reads
    /// changed, not that their files could not be found.
    func testABatchWhoseEverySampleWasSkippedForChangedReadsSaysSo() async throws {
        let root = try TestTempDirectory.make(prefix: "kraken2-batch-changed")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let batch = root.appendingPathComponent("kraken2-mini", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: batch)
        for sample in ["SRR35517702", "SRR35517703"] {
            let reads = batch.appendingPathComponent("\(sample)/source.fastq")
            let lines = try String(contentsOf: reads, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            try lines.enumerated().map { $0.offset % 2 == 1 ? String($0.element.dropLast()) : String($0.element) }
                .joined(separator: "\n").write(to: reads, atomically: true, encoding: .utf8)
        }

        do {
            let outcome = try await ClassifierReadResolver().resolveAndExtract(
                tool: .kraken2, resultPath: batch,
                selections: [
                    ClassifierRowSelector(sampleId: "SRR35517702", taxIds: [1270]),
                    ClassifierRowSelector(sampleId: "SRR35517703", taxIds: [1]),
                ],
                options: ExtractionOptions(), destination: .file(root.appendingPathComponent("out.fastq"))
            )
            XCTFail("Extract wrote \(outcome.readCount) reads from changed reads")
        } catch {
            let words = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(words.contains("trimmed, filtered or basecalled again"), words)
            XCTAssertFalse(words.contains("could not be found"), words)
        }
    }

    // MARK: - Fixture

    private func makeProject(records: [(String, Int)]) throws -> ReadIdentityProject {
        let root = try TestTempDirectory.make(prefix: "kraken2-read-identity-shapes")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let project = try ReadIdentityProject(root: root)
        try records.map { "@\($0.0)\n\(String(repeating: "A", count: $0.1))\n+\n\(String(repeating: "I", count: $0.1))\n" }
            .joined().write(to: project.payload, atomically: true, encoding: .utf8)
        return project
    }

    private func writeKrakenLines(_ lines: [String], in project: ReadIdentityProject) throws {
        try lines.map { $0 + "\t562:5\n" }.joined()
            .write(to: project.resultFolder.appendingPathComponent("classification.kraken"), atomically: true, encoding: .utf8)
    }

    private func extract(_ project: ReadIdentityProject) async throws -> ExtractionOutcome {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
            throw XCTSkip("managed seqkit is not installed")
        }
        return try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2, resultPath: project.resultFolder, selections: [ClassifierRowSelector(taxIds: [562])],
            options: ExtractionOptions(), destination: .file(project.output.appendingPathComponent("taxon.fastq"))
        )
    }
}
