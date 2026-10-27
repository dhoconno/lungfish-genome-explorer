// FASTQIngestionInPlaceLiveConformanceTests.swift - Today's in-place ingest with real clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M1 and M3 (BIO's objection 8, plan decision G1). Copying a FASTQ file into a
// project calls `FASTQIngestionService.ingestIfNeeded`, which clumpifies the file in place, replaces
// it with a `.fastq.gz`, writes the metadata sidecar and a provenance record, and deletes the
// original. M1 pinned the in-process route, whose pipeline removed the original before the sidecar
// and the record existed. M3 moved the row onto `lungfish-cli fastq ingest`, so this runs that route
// on the built CLI with the managed clumpify and pins the result, the sidecar, the record and the
// order: the original goes last. The in-process route is side A of `FastqIngestRouteParityReplayTests`.
//
// The command removes the original in its own process, which a `FileManagerDelegate` here never sees
// (the first run of this class on the CLI route saw no removal). The class watches the folder from
// outside and reads it whenever the folder changes with the original gone, and it holds the record's
// digest of the original, which the command can only take while the original exists.
// `FastqIngestPublishDurabilityTests` pins the exact moment in process.
//
// The class needs the managed clumpify, so it is named `Conformance` and never runs in the unit
// tier. It skips without the tool, and fails under `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
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

    /// Reads the folder whenever it changes while the watched original is gone. A reading comes a
    /// moment after the change it follows, so it cannot name the exact moment of the removal. Every
    /// reading with the original gone must still hold the output, the sidecar and the record, which
    /// is true only if they were written before the original was removed.
    private final class RemovalWitness: @unchecked Sendable {
        private let queue = DispatchQueue(label: "ingest-live-removal-witness")
        private let source: any DispatchSourceFileSystemObject
        private let lock = NSLock()
        private var seen: [FolderSnapshot] = []

        init?(watching folder: URL, snapshot: @escaping @Sendable () -> FolderSnapshot) {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: .write, queue: queue
            )
            source.setCancelHandler { close(descriptor) }
            source.setEventHandler { [weak self] in
                let state = snapshot()
                guard !state.original else { return }
                self?.record(state)
            }
            source.resume()
        }

        private func record(_ state: FolderSnapshot) {
            lock.lock()
            seen.append(state)
            lock.unlock()
        }

        /// Stops watching, lets the readings in flight finish and returns those taken with the original gone.
        func stop() -> [FolderSnapshot] {
            source.cancel()
            queue.sync {}
            lock.lock()
            defer { lock.unlock() }
            return seen
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

    func testInPlaceIngestReplacesTheFileWritesTheSidecarAndRecordAndRemovesTheOriginalLast() async throws {
        try await requireClumpify()
        let root = try TestTempDirectory.make(prefix: "ingest-live-in-place")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("SRR9_1.fastq")
        try Self.reads.joined().write(to: input, atomically: true, encoding: .utf8)
        let originalSize = Int64(try Data(contentsOf: input).count)
        let originalDigest = try ProvenanceFileHasher.sha256(of: input)
        // `deriveBaseName` drops the `_1`, so the file is replaced by a differently named one.
        let output = root.appendingPathComponent("SRR9.fastq.gz")
        let sidecar = FASTQMetadataStore.metadataURL(for: output)
        let recordFile = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)

        let witness = try XCTUnwrap(RemovalWitness(watching: root) {
            let fm = FileManager.default
            return FolderSnapshot(
                output: fm.fileExists(atPath: output.path),
                sidecar: fm.fileExists(atPath: sidecar.path),
                record: fm.fileExists(atPath: recordFile.path),
                original: fm.fileExists(atPath: input.path)
            )
        }, "the folder could not be watched")
        defer { _ = witness.stop() }

        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        FASTQIngestionService.ingestIfNeeded(
            url: input, pairingMode: .singleEnd, pairedFile: nil, existingMetadata: nil, routeContext: nil,
            runner: CLIReadsRunner(cliURLOverride: cli)
        )

        let title = "FASTQ Ingestion: SRR9"
        let finished = await waitUntil(timeout: .seconds(120)) {
            OperationCenter.shared.items.first { $0.title == title }.map { $0.state != .running } ?? false
        }
        XCTAssertTrue(finished, "the ingest row did not finish")
        let readings = witness.stop()
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.title == title })
        XCTAssertEqual(row.state, .completed, "row detail: \(row.detail)")

        // The result: the original is replaced by the clumpified gzip file.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: input.path), "the original is deleted (deleteOriginals: true)")
        XCTAssertTrue(fm.fileExists(atPath: output.path))
        // The route reads no platform, so it bins with the default of every platform, fiveStep (owner ruling of
        // 2026-10-27), which stores each Q40 score as Q37, the value of the last step.
        let binning = IngestionPlatform.defaultQualityBinning(for: .unknown)
        XCTAssertEqual(binning, .fiveStep, "the expected reads below hold each Q40 score as Q37")
        let binned = Self.reads.map { $0.replacingOccurrences(of: "IIIIIIIIIIIIIIII", with: "FFFFFFFFFFFFFFFF") }
        XCTAssertEqual(
            try records(of: output).sorted(),
            binned.sorted(),
            "the clumpified reads equal the original's with each Q40 score stored as Q37, in any order"
        )

        // The sidecar.
        let metadata = try XCTUnwrap(FASTQMetadataStore.load(for: output))
        let ingestion = try XCTUnwrap(metadata.ingestion)
        XCTAssertTrue(ingestion.isClumpified)
        XCTAssertTrue(ingestion.isCompressed)
        XCTAssertEqual(ingestion.pairingMode, .singleEnd)
        XCTAssertEqual(ingestion.qualityBinning, binning.rawValue, "the app's run bins with the import default")
        XCTAssertEqual(ingestion.originalFilenames, ["SRR9_1.fastq"])
        XCTAssertEqual(ingestion.originalSizeBytes, originalSize)
        XCTAssertGreaterThan(ingestion.storageOutputSizeBytes ?? 0, 0)

        // The record.
        let run = try XCTUnwrap(ProvenanceRecorder.load(from: root))
        XCTAssertEqual(run.name, "lungfish fastq ingest")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.steps.first?.toolName, "FASTQIngestionPipeline")
        XCTAssertTrue(run.steps.contains { $0.toolName == "clumpify.sh" }, "\(run.steps.map(\.toolName))")
        XCTAssertEqual(run.parameters["deleteOriginals"]?.booleanValue, true)
        XCTAssertEqual(run.parameters["binning"]?.stringValue, binning.rawValue)
        XCTAssertEqual(run.parameters["wasClumpified"]?.booleanValue, true)

        // The order. The command removes the original last, in its own process (BIO's objection 8).
        // A reading follows a folder change by a moment and the kernel merges changes, so this check
        // can miss an inverted order and never fails a correct one. Every reading with the original
        // gone holds the output, the sidecar and the record. The digest shows that the command read
        // the original before it went, not when the record was written. The order itself is proved at
        // the removal call by FastqIngestPublishDurabilityTests, which runs the same FastqIngestRun.
        XCTAssertFalse(readings.isEmpty, "the folder was read at least once after the original went")
        XCTAssertTrue(
            readings.allSatisfy { $0.output && $0.sidecar && $0.record },
            "the original goes after the output, the sidecar and the record: \(readings)"
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: recordFile))
        XCTAssertEqual(
            envelope.files.first { $0.role == .input && URL(fileURLWithPath: $0.path).lastPathComponent == input.lastPathComponent }?
                .checksumSHA256,
            originalDigest,
            "the record names the original with the digest taken before it was removed"
        )
    }
}
