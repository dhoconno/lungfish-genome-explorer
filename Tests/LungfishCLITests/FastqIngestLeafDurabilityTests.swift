// FastqIngestLeafDurabilityTests.swift - The steps, events and refusals of `fastq ingest`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M2. `FastqIngestPublishDurabilityTests` shows what the user sees, through
// the root parser, and fails at the base. These tests reach into the new leaf: the order of its
// steps against the system calls `DurableReplace` makes, a failed sync, the events it prints, a
// pair, a mismatched pair, and the input that stays as the output. The class name holds
// "Durability", so `scripts/testing/exfat-tests.sh --simulate` runs it with the ExFAT fallback
// renames.
//
// The runs need bgzip or pigz to compress, and they skip without them (a failure under
// `LUNGFISH_REQUIRE_TOOLS=1`). None needs clumpify, because each passes `--skip-clumpify`.

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// A log that a `@Sendable` closure can append to.
final class IngestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

final class FastqIngestLeafDurabilityTests: XCTestCase {
    private static let reads = FastqIngestPublishDurabilityTests.reads

    private func requireCompressor() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Runs the leaf in this process and returns the event lines it printed.
    @discardableResult
    private func execute(_ arguments: [String]) async throws -> [String] {
        let command = try FastqIngestSubcommand.parse(arguments)
        let lines = IngestLog()
        try await command.execute(emit: { lines.append($0) })
        return lines.all
    }

    private func object(_ line: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    // MARK: - Order

    func testTheStepsRunInTheOrderSyncRenameSidecarRecordThenDelete() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-steps")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        let log = IngestLog()
        var operations = DurableReplace.Operations()
        operations.fullFlush = { descriptor in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor, F_GETPATH, &buffer) != -1 {
                log.append("flush:" + URL(fileURLWithPath: String(cString: buffer)).lastPathComponent)
            }
            return fcntl(descriptor, F_FULLFSYNC)
        }
        try await DurableReplace.$overrideOperations.withValue(operations) {
            try await FastqIngestObservation.$observer.withValue({ log.append("step:\($0.rawValue)") }) {
                try await self.execute([input.path, "--skip-clumpify", "--delete-originals", "--quiet"])
            }
        }

        let entries = log.all
        let steps = entries.filter { $0.hasPrefix("step:") }
        XCTAssertEqual(
            steps,
            ["stageSynced", "renamed", "folderSynced", "sidecarWritten", "recorded", "originalsRemoved"].map { "step:\($0)" }
        )
        // The output is flushed to the drive under its hidden name, before the rename gives it
        // its final one, and the folder is flushed after it. `reads.fastq.gz` is the staged name.
        let stagedFlush = try XCTUnwrap(entries.firstIndex(of: "flush:reads.fastq.gz"), "\(entries)")
        let rename = try XCTUnwrap(entries.firstIndex(of: "step:renamed"))
        XCTAssertLessThan(stagedFlush, rename, "the output is synced before it is renamed")
        let sidecarFlush = try XCTUnwrap(entries.firstIndex(of: "flush:reads.fastq.gz.lungfish-meta.json"), "\(entries)")
        XCTAssertGreaterThan(sidecarFlush, rename)
        XCTAssertLessThan(sidecarFlush, try XCTUnwrap(entries.firstIndex(of: "step:sidecarWritten")))
    }

    func testAFailedSyncPublishesNothingAndLeavesTheOriginal() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-sync-fails")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        var operations = DurableReplace.Operations()
        operations.fullFlush = { _ in errno = EIO; return -1 }
        operations.syncFile = { _ in errno = EIO; return -1 }
        let steps = IngestLog()
        do {
            try await DurableReplace.$overrideOperations.withValue(operations) {
                try await FastqIngestObservation.$observer.withValue({ steps.append($0.rawValue) }) {
                    try await self.execute([input.path, "--skip-clumpify", "--delete-originals", "--format", "json", "--quiet"])
                }
            }
            XCTFail("a sync that fails must fail the run")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sync"), "\(error.localizedDescription)")
        }

        XCTAssertEqual(steps.all, [], "no step after the failed sync ran")
        XCTAssertEqual(try names(in: root), ["reads.fastq"], "the original stays, with no output, record, sidecar or hidden folder")
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads)
    }

    // MARK: - Events

    func testItPrintsEventsOnFormatJSON() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-events")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("reads.fastq.gz")

        let lines = try await execute([input.path, "--skip-clumpify", "--format", "json", "--quiet"])

        let events = try lines.map(object)
        XCTAssertEqual(events.first?["event"] as? String, "start")
        XCTAssertEqual(events.first?["message"] as? String, "Ingesting reads...")
        XCTAssertEqual(events.last?["event"] as? String, "complete")
        XCTAssertEqual(events.last?["outputs"] as? [String], [output.path])
        XCTAssertTrue((events.last?["message"] as? String)?.hasPrefix("Compressed (saved ") == true, "\(String(describing: events.last))")
        XCTAssertFalse(events.contains { $0["event"] as? String == "failed" })
        let fractions = events.compactMap { $0["progress"] as? Double }
        XCTAssertEqual(fractions, fractions.sorted(), "progress never moves back")
        XCTAssertTrue(fractions.dropLast().allSatisfy { $0 < 1 }, "only the complete line reaches 100%")
        XCTAssertTrue(
            events.contains { ($0["message"] as? String)?.contains("Interleaving") == true || ($0["message"] as? String)?.contains("Compress") == true },
            "the pipeline's own words reach the stream: \(lines)"
        )
    }

    func testAMissingInputIsAFailedEventAndWritesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-missing")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("SRR9_1.fastq")
        let lines = IngestLog()
        let command = try FastqIngestSubcommand.parse([input.path, "--format", "json", "--quiet"])
        do {
            try await command.execute(emit: { lines.append($0) })
            XCTFail("a missing input must fail the run")
        } catch {
            // Expected.
        }
        let events = try lines.all.map(object)
        XCTAssertEqual(events.map { $0["event"] as? String }, ["start", "failed"])
        XCTAssertEqual(events.last?["error"] as? String, "Input file not found: \(input.path)")
        XCTAssertEqual(try names(in: root), [], "nothing was created")
    }

    // MARK: - Pairs

    func testAPairBecomesOneInterleavedFileAndBothOriginalsGoLast() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-pair")
        defer { TestTempDirectory.cleanup(root) }
        let r1 = root.appendingPathComponent("Sample_R1.fastq")
        let r2 = root.appendingPathComponent("Sample_R2.fastq")
        try "@pair1/1\nACGTACGT\n+\nIIIIIIII\n@pair2/1\nTTGGCCAA\n+\nIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@pair1/2\nGGCCTTAA\n+\nIIIIIIII\n@pair2/2\nCCAATTGG\n+\nIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        let digests = [try ProvenanceFileHasher.sha256(of: r1), try ProvenanceFileHasher.sha256(of: r2)]
        let output = root.appendingPathComponent("Sample.fastq.gz")

        let probe = IngestRemovalMomentProbe(watching: [r1, r2]) {
            IngestPublishMoment.read(root: root, original: r1, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }
        try await execute([r1.path, "--pair", r2.path, "--skip-clumpify", "--delete-originals", "--quiet"])

        XCTAssertEqual(probe.moments.count, 2)
        XCTAssertTrue(probe.moments.allSatisfy { $0.output && $0.sidecar && $0.record }, "\(probe.moments)")
        XCTAssertEqual(try names(in: root).filter { !$0.hasPrefix(".") }, ["Sample.fastq.gz", "Sample.fastq.gz.lungfish-meta.json", "Sample.fastq.gz.lungfish-provenance.json"])
        var headers: [String] = []
        try output.forEachLineAutoDecompressing { headers.append($0) }
        XCTAssertEqual(stride(from: 0, to: headers.count, by: 4).map { headers[$0] }, ["@pair1/1", "@pair1/2", "@pair2/1", "@pair2/2"])
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: output)?.ingestion)
        XCTAssertEqual(ingestion.pairingMode, .interleaved)
        XCTAssertEqual(ingestion.originalFilenames, ["Sample_R1.fastq", "Sample_R2.fastq"])
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(
            [r1, r2].map { url in envelope.files.first { $0.role == .input && $0.path == url.path }?.checksumSHA256 },
            digests,
            "the record names each original with its digest"
        )
    }

    func testAFileThatHoldsTheOutputsNameIsSwappedOutAndItsOldCopyGoesWithTheHiddenFolder() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-swap")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("reads.fastq.gz")
        try Data("an older output".utf8).write(to: output)

        try await execute([input.path, "--skip-clumpify", "--delete-originals", "--quiet"])

        var lines: [String] = []
        try output.forEachLineAutoDecompressing { lines.append($0) }
        XCTAssertEqual(lines.joined(separator: "\n") + "\n", Self.reads, "the name holds the new output")
        XCTAssertEqual(
            try names(in: root).filter { !$0.hasPrefix(".lungfish-provenance") },
            ["reads.fastq.gz", "reads.fastq.gz.lungfish-meta.json", "reads.fastq.gz.lungfish-provenance.json"],
            "the old copy, any swap tombstone and the hidden folder are gone, and so is the original"
        )
    }

    func testAMismatchedPairLeavesBothOriginalsAndNoOutput() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-mismatch")
        defer { TestTempDirectory.cleanup(root) }
        let r1 = root.appendingPathComponent("Sample_R1.fastq")
        let r2 = root.appendingPathComponent("Sample_R2.fastq")
        try "@pair1/1\nACGTACGT\n+\nIIIIIIII\n@pair2/1\nTTGGCCAA\n+\nIIIIIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@pair1/2\nGGCCTTAA\n+\nIIIIIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        let before = [try Data(contentsOf: r1), try Data(contentsOf: r2)]

        let lines = IngestLog()
        let command = try FastqIngestSubcommand.parse([r1.path, "--pair", r2.path, "--skip-clumpify", "--delete-originals", "--format", "json", "--quiet"])
        do {
            try await command.execute(emit: { lines.append($0) })
            XCTFail("a mismatched pair must not be ingested")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try names(in: root), ["Sample_R1.fastq", "Sample_R2.fastq"], "no output, record, sidecar or hidden folder")
        XCTAssertEqual([try Data(contentsOf: r1), try Data(contentsOf: r2)], before)
        XCTAssertEqual(try lines.all.map(object).last?["event"] as? String, "failed")
    }

    // MARK: - The input that stays as the output

    func testAGzipInputWithClumpifySkippedStaysAsTheOutputAndIsNeverRemoved() async throws {
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-passthrough")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00]).write(to: input)
        let digest = try ProvenanceFileHasher.sha256(of: input)

        try await execute([input.path, "--skip-clumpify", "--delete-originals", "--quiet"])

        XCTAssertEqual(try Data(contentsOf: input), Data([0x1f, 0x8b, 0x08, 0x00]), "the input is the output, so it stays")
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: input)?.ingestion)
        XCTAssertFalse(ingestion.isClumpified)
        XCTAssertEqual(try names(in: root).filter { !$0.hasPrefix(".lungfish-provenance") }, ["reads.fastq.gz", "reads.fastq.gz.lungfish-meta.json", "reads.fastq.gz.lungfish-provenance.json"])
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(envelope.files.first { $0.role == .input && $0.path == input.path }?.checksumSHA256, digest)
    }

    func testTheOutputNameDropsTheMateSuffixAndAvoidsTheInputsOwnName() {
        let folder = URL(fileURLWithPath: "/work/project", isDirectory: true)
        let mate = FastqIngestRun.finalOutputURL(folder: folder, inputs: [folder.appendingPathComponent("SRR9_1.fastq")])
        XCTAssertEqual(mate.path, "/work/project/SRR9.fastq.gz")
        let same = FastqIngestRun.finalOutputURL(folder: folder, inputs: [folder.appendingPathComponent("reads.fastq.gz")])
        XCTAssertEqual(same.path, "/work/project/reads.clumped.fastq.gz", "an input that holds the output's name keeps it until the run ends")
    }
}
