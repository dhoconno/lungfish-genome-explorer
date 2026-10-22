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

    /// 2.11 S32 M3 review Group 1 fix 4. An input outside a project stages in the system temp folder (2.11 S8),
    /// so `TMPDIR` names a folder of this test's own and no run stages in the real one.
    private var systemTemp: URL!
    private var previousTMPDIR: String?

    override func setUpWithError() throws {
        systemTemp = try TestTempDirectory.make(prefix: "fastq-ingest-publish-tmp")
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(systemTemp)
    }

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

        try await runRoot(["fastq", "ingest", input.path, "--skip-clumpify", "--delete-originals", "--binning", "none", "--quiet"])

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
        XCTAssertEqual(ingestion.qualityBinning, QualityBinningScheme.none.rawValue, "binning is off when --binning none asks for it")
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

    /// Lane A47 M3, ruling section 1. The one caller ingests a FASTQ file that the app has just
    /// bundled with the download's record, and the app's route merges its run into that record.
    /// The leaf did not, so a copy-in of a download lost the download's steps. The record keeps the
    /// import step first, then the ingest, and the deleted original's output now names the gzip file.
    func testTheRecordKeepsTheImportRecord() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-merge")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = try FastqIngestImportRecordFixture.makeBundle(in: root, reads: Self.reads)
        let originalDigest = try ProvenanceFileHasher.sha256(of: fixture.fastq)
        let output = fixture.folder.appendingPathComponent("Sample.fastq.gz")

        try await runRoot(["fastq", "ingest", fixture.fastq.path, "--skip-clumpify", "--delete-originals", "--quiet"])

        let record = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: fixture.folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(record.steps.first?.toolName, "lungfish-cli", "the download's step stays first: \(record.steps.map(\.toolName))")
        XCTAssertTrue(record.steps.contains { $0.toolName == "FASTQIngestionPipeline" }, "the ingest adds its steps after it")
        XCTAssertFalse(record.outputs.contains { $0.path == fixture.fastq.path }, "the removed original is no output of the record")
        XCTAssertTrue(record.outputs.contains { $0.path == output.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(
            record.files.first { $0.role == .input && $0.path == fixture.fastq.path }?.checksumSHA256,
            originalDigest,
            "the record still names the original with its digest"
        )
    }
}

/// A FASTQ file as the app leaves it after a copy-in of a download, which is the one place the
/// in-place ingest runs. The download's record travels with the file (`rehydrateImportedCopy`). A
/// `.lungfishfastq` bundle holds it as the folder's root record. A folder with no root record can hold
/// it as the file's own sidecar alone, which the lookup of the merge finds as well.
enum FastqIngestImportRecordFixture {
    struct Imported {
        /// The folder the ingest records into.
        let folder: URL
        let fastq: URL
    }

    static func makeBundle(in root: URL, reads: String) throws -> Imported {
        try make(folder: root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true), in: root, reads: reads, sidecarOnly: false)
    }

    static func makeSidecarOnly(in root: URL, reads: String) throws -> Imported {
        try make(folder: root.appendingPathComponent("project", isDirectory: true), in: root, reads: reads, sidecarOnly: true)
    }

    private static func make(folder: URL, in root: URL, reads: String, sidecarOnly: Bool) throws -> Imported {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imported = folder.appendingPathComponent("Sample.fastq")
        try reads.write(to: imported, atomically: true, encoding: .utf8)

        let download = root.appendingPathComponent("cli-download.fastq")
        try reads.write(to: download, atomically: true, encoding: .utf8)
        let argv = ["lungfish-cli", "fetch", "ncbi", "SRR123", "--output", download.path]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Download",
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "2026.05"
        )
        .argv(argv)
        .output(download, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli",
                toolVersion: "2026.05",
                argv: argv,
                outputs: [try ProvenanceFileDescriptor.file(url: download, format: .fastq, role: .output)],
                exitStatus: 0,
                wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(
            exitStatus: 0,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 11)
        )
        let writer = ProvenanceWriter(signingProvider: nil)
        if sidecarOnly {
            try writer.write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: imported))
        } else {
            try writer.write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: download))
            try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: download, to: imported)
        }
        return Imported(folder: folder, fastq: imported)
    }
}
