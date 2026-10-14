// FastqIngestInPlacePinTests.swift - Pins when the original goes in today's in-place FASTQ ingest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M1, BIO's objection 8. Copying a FASTQ file into a project runs
// `FASTQIngestionPipeline` with `deleteOriginals: true`, and the pipeline removes the original
// inside `run`, before its caller writes the metadata sidecar or the record. These pins show that
// order at the base on the CLI's closest route, `debug fastq-ingest --delete-originals`, and on
// the pipeline the app calls. They carry no `Sources` edit and pass at the base. Lane A47 M2
// changes the order on the new `fastq ingest` leaf, which publishes the output, writes the
// sidecar and the record, and removes the original last. The pipeline pin stays as the record of
// what the app's route did. The `debug fastq-ingest` pin changed in lane A47 M3, which fixed that
// command to record the original before it removes it (the first version of the pin showed the
// defect, an `unreadableFile` failure after the original was gone).
//
// A `FileManagerDelegate` on the shared manager sees each removal before it happens, so the probe
// reads the state of the output, the sidecar and the record at the exact moment the original is
// asked to go. That is exact where polling the folder would race the next step.
//
// The runs need bgzip or pigz to compress, as the pipeline tests beside them do, and they skip
// without them (a failure under `LUNGFISH_REQUIRE_TOOLS=1`). No run needs clumpify, because the
// pins pass `--skip-clumpify`. The run with real clumpify is `FASTQIngestionInPlaceLiveConformanceTests`.

import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// What exists on disk at one moment.
struct IngestFolderSnapshot: Equatable, Sendable, CustomStringConvertible {
    var output: Bool
    var sidecar: Bool
    var record: Bool
    var original: Bool

    var description: String {
        "output=\(output) sidecar=\(sidecar) record=\(record) original=\(original)"
    }
}

/// Sees each removal the shared `FileManager` is about to make, and reads the folder at the moment
/// the watched original is asked to go. It always lets the removal proceed.
final class OriginalRemovalProbe: NSObject, FileManagerDelegate, @unchecked Sendable {
    private let watched: Set<String>
    private let snapshot: @Sendable () -> IngestFolderSnapshot
    private let lock = NSLock()
    private var seen: [(path: String, snapshot: IngestFolderSnapshot)] = []

    init(watching originals: [URL], snapshot: @escaping @Sendable () -> IngestFolderSnapshot) {
        watched = Set(originals.map { $0.standardizedFileURL.path })
        self.snapshot = snapshot
    }

    /// One entry per removal of a watched original, in the order they happened.
    var removals: [(path: String, snapshot: IngestFolderSnapshot)] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func fileManager(_ fileManager: FileManager, shouldRemoveItemAt URL: URL) -> Bool {
        if watched.contains(URL.standardizedFileURL.path) {
            let state = snapshot()
            lock.lock()
            seen.append((URL.standardizedFileURL.path, state))
            lock.unlock()
        }
        return true
    }
}

final class FastqIngestInPlacePinTests: XCTestCase {
    private static let reads = """
    @read1
    ACGTACGTACGT
    +
    IIIIIIIIIIII
    @read2
    TTGGCCAATTGG
    +
    IIIIIIIIIIII

    """

    private func requireCompressor() async throws {
        let runner = NativeToolRunner.shared
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    private static func snapshot(root: URL, input: URL, output: URL) -> IngestFolderSnapshot {
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        return IngestFolderSnapshot(
            output: exists(output),
            sidecar: exists(FASTQMetadataStore.metadataURL(for: output)),
            record: exists(root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
                || exists(ProvenanceRecorder.fileSidecarURL(for: output)),
            original: exists(input)
        )
    }

    // MARK: - The pipeline the app calls

    func testThePipelineRemovesTheOriginalOnceTheOutputExistsAndBeforeTheCallerWritesAnything() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "ingest-pin-pipeline")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("reads.fastq.gz")
        let sidecar = FASTQMetadataStore.metadataURL(for: output)

        let probe = OriginalRemovalProbe(watching: [input]) {
            Self.snapshot(root: root, input: input, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }

        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [input],
                outputDirectory: root,
                threads: 1,
                deleteOriginals: true,
                qualityBinning: .none,
                clumpingTool: .none
            ),
            progress: { _, _ in }
        )

        XCTAssertEqual(result.outputFile.standardizedFileURL, output.standardizedFileURL)
        XCTAssertEqual(probe.removals.map(\.path), [input.standardizedFileURL.path], "the pipeline removes the one original")
        XCTAssertEqual(
            probe.removals.first?.snapshot,
            IngestFolderSnapshot(output: true, sidecar: false, record: false, original: true),
            "the output exists when the original is removed, and the pipeline has written neither a sidecar nor a record"
        )
        XCTAssertEqual(
            Self.snapshot(root: root, input: input, output: output),
            IngestFolderSnapshot(output: true, sidecar: false, record: false, original: false),
            "when run returns the original is gone, and the pipeline never writes the sidecar or the record, its caller does"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }

    // MARK: - debug fastq-ingest

    /// The finding of this lane's first pin, fixed in lane A47 M3 (the ruling on M3 makes the fix
    /// A47's). `debug fastq-ingest --delete-originals` used to run the pipeline with
    /// `deleteOriginals: true`, which removed the original, and only then recorded the run. The
    /// record call hashes the original by path, and the file was gone, so the command threw
    /// `unreadableFile` after the original and before any record, and left the output, no record,
    /// no sidecar and a failed exit. The pipeline now never deletes. The record names the original
    /// with its digest, and only then does the command remove the original, as `fastq ingest` does.
    /// The command still leaves the metadata sidecar unwritten, since it is a diagnostic.
    func testDebugFastqIngestRecordsTheOriginalBeforeRemovingItAndWritesNoSidecar() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "ingest-pin-debug")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let originalDigest = try ProvenanceFileHasher.sha256(of: input)
        let output = root.appendingPathComponent("reads.fastq.gz")
        let sidecar = FASTQMetadataStore.metadataURL(for: output)

        let probe = OriginalRemovalProbe(watching: [input]) {
            Self.snapshot(root: root, input: input, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }

        let command = try FASTQIngestSubcommand.parse([
            input.path,
            "--output-dir", root.path,
            "--skip-clumpify",
            "--binning", "none",
            "--delete-originals",
            "--quiet",
        ])
        try await command.run()

        XCTAssertEqual(
            probe.removals.map(\.snapshot),
            [IngestFolderSnapshot(output: true, sidecar: false, record: true, original: true)],
            "the original goes once the output and the record exist"
        )
        XCTAssertEqual(
            Self.snapshot(root: root, input: input, output: output),
            IngestFolderSnapshot(output: true, sidecar: false, record: true, original: false),
            "the run succeeds, the original is gone and the output and the record stand"
        )
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(
            envelope.files.first { $0.role == .input && $0.path == input.path }?.checksumSHA256,
            originalDigest,
            "the record names the original with the digest taken before it was removed"
        )
        XCTAssertEqual(envelope.options.explicit["deleteOriginals"]?.booleanValue, true, "the record keeps the flag the user gave")
        XCTAssertNil(FASTQMetadataStore.load(for: output), "debug fastq-ingest leaves the metadata sidecar unwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
    }
}
