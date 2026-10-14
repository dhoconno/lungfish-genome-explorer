// FastqIngestPublishDurabilityTests.swift - `fastq ingest` records the original before it removes it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2, BIO's objection 8 and SWIFT's L6 row. The in-place ingest deletes the
// user's original FASTQ file, so the new `fastq ingest` leaf publishes in the order write, sync,
// rename, sidecar, record, then delete. `FastqIngestInPlacePinTests` shows the order at the base:
// the pipeline removes the original first, and `debug fastq-ingest --delete-originals` then
// throws from its record call and leaves no record at all.
//
// These tests parse the command through the root parser, as a user's shell does, and so they
// fail at the base with the parser's `unexpected argument` error. A `FileManagerDelegate` reads
// the folder, and the digest the record holds, at the moment the original is asked to go. The
// class name holds "Durability", so `scripts/testing/exfat-tests.sh --simulate` runs it with
// every rename on its ExFAT fallback.
//
// The runs need bgzip or pigz to compress, and they skip without them (a failure under
// `LUNGFISH_REQUIRE_TOOLS=1`). None needs clumpify, because each passes `--skip-clumpify`.

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// The folder at one moment of an ingest, and the digest its record holds for the original.
struct IngestPublishMoment: Equatable, Sendable, CustomStringConvertible {
    var output: Bool
    var sidecar: Bool
    var record: Bool
    var original: Bool
    var recordedOriginalDigest: String?

    var description: String {
        "output=\(output) sidecar=\(sidecar) record=\(record) original=\(original) digest=\(recordedOriginalDigest ?? "none")"
    }

    static func read(root: URL, original: URL, output: URL) -> IngestPublishMoment {
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        let recordURL = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try? ProvenanceEnvelopeReader.load(fromSidecar: recordURL)
        let digest = envelope?.files.first { $0.role == .input && $0.path == original.path }?.checksumSHA256
        return IngestPublishMoment(
            output: exists(output),
            sidecar: exists(FASTQMetadataStore.metadataURL(for: output)),
            record: exists(recordURL),
            original: exists(original),
            recordedOriginalDigest: digest
        )
    }
}

/// Reads the folder when each watched original is asked to go, and lets the removal proceed.
final class IngestRemovalMomentProbe: NSObject, FileManagerDelegate, @unchecked Sendable {
    private let watched: Set<String>
    private let read: @Sendable () -> IngestPublishMoment
    private let lock = NSLock()
    private var seen: [IngestPublishMoment] = []

    init(watching originals: [URL], read: @escaping @Sendable () -> IngestPublishMoment) {
        watched = Set(originals.map { $0.standardizedFileURL.path })
        self.read = read
    }

    var moments: [IngestPublishMoment] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func fileManager(_ fileManager: FileManager, shouldRemoveItemAt URL: URL) -> Bool {
        if watched.contains(URL.standardizedFileURL.path) {
            let moment = read()
            lock.lock()
            seen.append(moment)
            lock.unlock()
        }
        return true
    }
}

final class FastqIngestPublishDurabilityTests: XCTestCase {
    static let reads = "@read1\nACGTACGTACGT\n+\nIIIIIIIIIIII\n@read2\nTTGGCCAATTGG\n+\nIIIIIIIIIIII\n"

    private func requireCompressor() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    /// Parses `arguments` as the root command does and runs the leaf it finds.
    private func runRoot(_ arguments: [String]) async throws {
        var parsed = try LungfishCLI.parseAsRoot(arguments)
        guard var leaf = parsed as? any AsyncParsableCommand else {
            return try parsed.run()
        }
        try await leaf.run()
    }

    func testTheRecordNamesTheOriginalsDigestAndExistsBeforeTheOriginalIsRemoved() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-order")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let originalDigest = try ProvenanceFileHasher.sha256(of: input)
        let originalSize = UInt64(try Data(contentsOf: input).count)
        let output = root.appendingPathComponent("reads.fastq.gz")

        let probe = IngestRemovalMomentProbe(watching: [input]) {
            IngestPublishMoment.read(root: root, original: input, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }

        try await runRoot(["fastq", "ingest", input.path, "--skip-clumpify", "--delete-originals", "--quiet"])

        XCTAssertEqual(
            probe.moments,
            [IngestPublishMoment(
                output: true, sidecar: true, record: true, original: true, recordedOriginalDigest: originalDigest
            )],
            "the output, its sidecar and a record that holds the original's digest exist before the original is removed"
        )

        // The result.
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path), "--delete-originals removes the original last")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        var lines: [String] = []
        try output.forEachLineAutoDecompressing { lines.append($0) }
        XCTAssertEqual(lines.joined(separator: "\n") + "\n", Self.reads, "the output holds the original's reads")

        // The sidecar, as the app's route writes it.
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: output)?.ingestion)
        XCTAssertFalse(ingestion.isClumpified, "--skip-clumpify")
        XCTAssertTrue(ingestion.isCompressed)
        XCTAssertEqual(ingestion.pairingMode, .singleEnd)
        XCTAssertEqual(ingestion.qualityBinning, QualityBinningScheme.none.rawValue, "binning is off unless it is asked for")
        XCTAssertEqual(ingestion.originalFilenames, ["reads.fastq"])
        XCTAssertEqual(ingestion.originalSizeBytes, Int64(originalSize))

        // The record.
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish fastq ingest")
        XCTAssertEqual(envelope.status, .completed)
        XCTAssertEqual(
            Array(envelope.argv.prefix(4)),
            [CLICommandIdentity.executableName, "fastq", "ingest", input.path]
        )
        XCTAssertTrue(envelope.argv.contains("--delete-originals"))
        let recordedInput = try XCTUnwrap(envelope.files.first { $0.role == .input && $0.path == input.path })
        XCTAssertEqual(recordedInput.checksumSHA256, originalDigest)
        XCTAssertEqual(recordedInput.fileSize, originalSize)
        XCTAssertTrue(envelope.outputs.contains { $0.path == output.path && $0.checksumSHA256 != nil })
    }

    func testWithoutDeleteOriginalsTheOriginalStaysAndTheRecordStillNamesIt() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-keep")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let originalDigest = try ProvenanceFileHasher.sha256(of: input)
        let output = root.appendingPathComponent("reads.fastq.gz")

        let probe = IngestRemovalMomentProbe(watching: [input]) {
            IngestPublishMoment.read(root: root, original: input, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }

        try await runRoot(["fastq", "ingest", input.path, "--skip-clumpify", "--quiet"])

        XCTAssertEqual(probe.moments, [], "nothing asks for the original to go")
        XCTAssertEqual(
            IngestPublishMoment.read(root: root, original: input, output: output),
            IngestPublishMoment(output: true, sidecar: true, record: true, original: true, recordedOriginalDigest: originalDigest)
        )
        XCTAssertEqual(try Data(contentsOf: input), Data(Self.reads.utf8), "the original is untouched")
    }
}
