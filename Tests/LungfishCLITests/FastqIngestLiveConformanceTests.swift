// FastqIngestLiveConformanceTests.swift - `fastq ingest` with the managed clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2 (plan decision G1, 2.9 O5). `FASTQIngestionInPlaceLiveConformanceTests`
// pins today's in-place route on a fixture with real clumpify. This runs the new leaf on the same
// fixture and holds it to the same result, sidecar and reads, with the order changed as the lane
// asks: the output, its sidecar and a record that holds the original's digest exist before the
// original is removed. Lane A47 M3 puts the two routes side by side on `RouteParityHarness`.
//
// The class needs the managed clumpify, so it is named `Conformance` and never runs in the unit
// tier. It skips without the tool, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class FastqIngestLiveConformanceTests: XCTestCase {
    /// 2.11 S32 M3 review Group 1 fix 4. An input outside a project stages in the system temp folder (2.11 S8),
    /// so `TMPDIR` names a folder of this test's own and no run stages in the real one.
    private var systemTemp: URL!
    private var previousTMPDIR: String?

    override func setUpWithError() throws {
        systemTemp = try TestTempDirectory.make(prefix: "fastq-ingest-live-tmp")
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(systemTemp)
    }

    /// The fixture of `FASTQIngestionInPlaceLiveConformanceTests`: four single-end reads, none a
    /// duplicate, so clumpify may reorder them and drops none.
    private static let reads = [
        "@SRR9.1 a/1\nACGTACGTACGTAAAC\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.2 b/1\nTTGGCCAATTGGCCAA\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.3 c/1\nGGGGCCCCAAAATTTT\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.4 d/1\nCATGCATGCATGCATG\n+\nIIIIIIIIIIIIIIII\n",
    ]

    func testTheLeafClumpifiesTheFileAndPublishesItBeforeTheOriginalGoes() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-live")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.joined().write(to: input, atomically: true, encoding: .utf8)
        let originalSize = Int64(try Data(contentsOf: input).count)
        let originalDigest = try ProvenanceFileHasher.sha256(of: input)
        // `deriveBaseName` drops the `_1`, so the file is replaced by a differently named one.
        let output = root.appendingPathComponent("SRR9.fastq.gz")

        let probe = IngestRemovalMomentProbe(watching: [input]) {
            IngestPublishMoment.read(root: root, original: input, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }

        let command = try FastqIngestSubcommand.parse([input.path, "--delete-originals", "--binning", "none", "--quiet"])
        try await command.execute(emit: { _ in })

        XCTAssertEqual(
            probe.moments,
            [IngestPublishMoment(output: true, sidecar: true, record: true, original: true, recordedOriginalDigest: originalDigest)],
            "the output, its sidecar and the record that names the original's digest exist before the original goes"
        )

        // The result, as the app's route leaves it.
        let fileManager = FileManager.default
        XCTAssertFalse(fileManager.fileExists(atPath: input.path))
        XCTAssertTrue(fileManager.fileExists(atPath: output.path))
        var lines: [String] = []
        try output.forEachLineAutoDecompressing { lines.append($0) }
        let records = stride(from: 0, to: lines.count, by: 4).map { lines[$0..<min($0 + 4, lines.count)].joined(separator: "\n") + "\n" }
        XCTAssertEqual(records.sorted(), Self.reads.sorted(), "the clumpified reads equal the original's, in any order")

        // The sidecar, field for field as the app's route writes it.
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: output)?.ingestion)
        XCTAssertTrue(ingestion.isClumpified)
        XCTAssertTrue(ingestion.isCompressed)
        XCTAssertEqual(ingestion.pairingMode, .singleEnd)
        XCTAssertEqual(ingestion.qualityBinning, QualityBinningScheme.none.rawValue)
        XCTAssertEqual(ingestion.originalFilenames, ["SRR9_1.fastq"])
        XCTAssertEqual(ingestion.originalSizeBytes, originalSize)
        XCTAssertGreaterThan(ingestion.storageOutputSizeBytes ?? 0, 0)

        // The record names the clumpify step against the final file, not the staging folder.
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(envelope.status, .completed)
        let clumpify = try XCTUnwrap(envelope.steps.first { $0.toolName == "clumpify.sh" })
        XCTAssertTrue(clumpify.argv.contains("out=\(output.path)"), "\(clumpify.argv)")
        XCTAssertFalse(clumpify.argv.joined(separator: " ").contains("lungfish-ingest-"))
        XCTAssertTrue(clumpify.outputs.contains { $0.path == output.path })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            [".lungfish-provenance.json", "SRR9.fastq.gz", "SRR9.fastq.gz.lungfish-meta.json", "SRR9.fastq.gz.lungfish-provenance.json"],
            "no hidden folder remains"
        )
    }
}
