// FASTQIngestionInPlaceLiveConformanceTests.swift - Today's in-place ingest with real clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M1 (BIO's objection 8, plan decision G1). Copying a FASTQ file into a
// project calls `FASTQIngestionService.ingestIfNeeded`, which clumpifies the file in place, replaces
// it with a `.fastq.gz`, writes the metadata sidecar and a provenance record, and deletes the
// original. This runs that route on a fixture with the managed clumpify and pins the result, the
// sidecar, the record and the order in which they appear. It carries no `Sources` edit and passes
// at the base.
//
// The order is the finding. The pipeline removes the original inside `run`, and the service
// writes the sidecar and the record after `run` returns, so the original is gone before either
// exists. A `FileManagerDelegate` on the shared manager reads the folder at the moment the original
// is asked to go. Lane A47 M3 moves this row onto `lungfish-cli fastq ingest`, which publishes the
// output, writes the sidecar and the record, and removes the original last. This pin then moves
// with it, in the commit that moves the row.
//
// The class needs the managed clumpify, so it is named `Conformance` and never runs in the unit
// tier. It skips without the tool, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class FASTQIngestionInPlaceLiveConformanceTests: XCTestCase {
    private struct FolderSnapshot: Equatable, CustomStringConvertible {
        var output: Bool
        var sidecar: Bool
        var record: Bool
        var original: Bool

        var description: String {
            "output=\(output) sidecar=\(sidecar) record=\(record) original=\(original)"
        }
    }

    /// Reads the folder at the moment the watched original is asked to go.
    private final class RemovalProbe: NSObject, FileManagerDelegate, @unchecked Sendable {
        private let watched: String
        private let snapshot: @Sendable () -> FolderSnapshot
        private let lock = NSLock()
        private var seen: [FolderSnapshot] = []

        init(watching original: URL, snapshot: @escaping @Sendable () -> FolderSnapshot) {
            watched = original.standardizedFileURL.path
            self.snapshot = snapshot
        }

        var removals: [FolderSnapshot] {
            lock.lock()
            defer { lock.unlock() }
            return seen
        }

        func fileManager(_ fileManager: FileManager, shouldRemoveItemAt URL: URL) -> Bool {
            if URL.standardizedFileURL.path == watched {
                let state = snapshot()
                lock.lock()
                seen.append(state)
                lock.unlock()
            }
            return true
        }
    }

    /// Four single-end reads, none a duplicate, so clumpify may reorder them and drops none.
    private static let reads = [
        "@SRR9.1 a/1\nACGTACGTACGTAAAC\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.2 b/1\nTTGGCCAATTGGCCAA\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.3 c/1\nGGGGCCCCAAAATTTT\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.4 d/1\nCATGCATGCATGCATG\n+\nIIIIIIIIIIIIIIII\n",
    ]

    private func requireClumpify() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
    }

    private func records(of url: URL) throws -> [String] {
        var lines: [String] = []
        try url.forEachLineAutoDecompressing { lines.append($0) }
        return stride(from: 0, to: lines.count, by: 4).map { lines[$0..<min($0 + 4, lines.count)].joined(separator: "\n") + "\n" }
    }

    func testInPlaceIngestReplacesTheFileWritesTheSidecarAndRecordAndRemovesTheOriginalFirst() async throws {
        try await requireClumpify()
        let root = try TestTempDirectory.make(prefix: "ingest-live-in-place")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.joined().write(to: input, atomically: true, encoding: .utf8)
        let originalSize = Int64(try Data(contentsOf: input).count)
        // `deriveBaseName` drops the `_1`, so the file is replaced by a differently named one.
        let output = root.appendingPathComponent("SRR9.fastq.gz")
        let sidecar = FASTQMetadataStore.metadataURL(for: output)
        let recordFile = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        let probe = RemovalProbe(watching: input) {
            let fm = FileManager.default
            return FolderSnapshot(
                output: fm.fileExists(atPath: output.path),
                sidecar: fm.fileExists(atPath: sidecar.path),
                record: fm.fileExists(atPath: recordFile.path),
                original: fm.fileExists(atPath: input.path)
            )
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }

        FASTQIngestionService.ingestIfNeeded(url: input)

        let title = "FASTQ Ingestion: SRR9"
        let finished = await waitUntil(timeout: .seconds(120)) {
            OperationCenter.shared.items.first { $0.title == title }.map { $0.state != .running } ?? false
        }
        XCTAssertTrue(finished, "the ingest row did not finish")
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == title })
        XCTAssertEqual(row.state, .completed, "row detail: \(row.detail)")

        // The result: the original is replaced by the clumpified gzip file.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: input.path), "the original is deleted (deleteOriginals: true)")
        XCTAssertTrue(fm.fileExists(atPath: output.path))
        XCTAssertEqual(
            try records(of: output).sorted(),
            Self.reads.sorted(),
            "the clumpified reads equal the original's, in any order"
        )

        // The sidecar.
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: output))
        let ingestion = try XCTUnwrap(metadata.ingestion)
        XCTAssertTrue(ingestion.isClumpified)
        XCTAssertTrue(ingestion.isCompressed)
        XCTAssertEqual(ingestion.pairingMode, .singleEnd)
        XCTAssertEqual(ingestion.qualityBinning, QualityBinningScheme.none.rawValue, "the app's run applies no quality binning")
        XCTAssertEqual(ingestion.originalFilenames, ["SRR9_1.fastq"])
        XCTAssertEqual(ingestion.originalSizeBytes, originalSize)
        XCTAssertGreaterThan(ingestion.storageOutputSizeBytes ?? 0, 0)

        // The record.
        let run = try XCTUnwrap(ProvenanceRecorder.load(from: root))
        XCTAssertEqual(run.name, "FASTQ Ingestion")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.steps.map(\.toolName), ["clumpify.sh", "lungfish-app"])
        XCTAssertEqual(run.parameters["deleteOriginals"]?.booleanValue, true)
        XCTAssertEqual(run.parameters["qualityBinning"]?.stringValue, QualityBinningScheme.none.rawValue)
        XCTAssertEqual(run.parameters["wasClumpified"]?.booleanValue, true)

        // The order. The original goes while the output exists and neither the sidecar nor the
        // record does, because the service writes both after the pipeline returns.
        XCTAssertEqual(probe.removals.count, 1, "the original is removed once")
        XCTAssertEqual(
            probe.removals.first,
            FolderSnapshot(output: true, sidecar: false, record: false, original: true),
            "today's order is output, original removed, sidecar, record"
        )
    }
}
