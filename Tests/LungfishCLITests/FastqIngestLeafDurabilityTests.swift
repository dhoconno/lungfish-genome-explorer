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

    /// 2.11 S32 M3 review Group 1 fix 4. An input outside a project stages in the system temp folder (2.11 S8),
    /// so `TMPDIR` names a folder of this test's own and no run stages in the real one.
    private var rootedSystemTemp: URL!
    private var previousTMPDIR: String?

    override func setUpWithError() throws {
        rootedSystemTemp = try TestTempDirectory.make(prefix: "fastq-ingest-leaf-tmp")
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", rootedSystemTemp.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(rootedSystemTemp)
    }

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

    /// Runs the leaf in this process on `input` with every sync failing. Returns the error the run ended
    /// with, nil when it did not fail, and the steps that ran.
    private func executeWithFailingSyncs(on input: URL) async -> (error: (any Error)?, steps: [String]) {
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
            return (nil, steps.all)
        } catch {
            return (error, steps.all)
        }
    }

    func testAFailedSyncPublishesNothingAndLeavesTheOriginal() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-sync-fails")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        let outcome = await executeWithFailingSyncs(on: input)

        let error = try XCTUnwrap(outcome.error, "a sync that fails must fail the run")
        XCTAssertTrue(error.localizedDescription.contains("sync"), "\(error.localizedDescription)")
        XCTAssertEqual(outcome.steps, [], "no step after the failed sync ran")
        XCTAssertEqual(try names(in: root), ["reads.fastq"], "the original stays, with no output, record, sidecar or hidden folder")
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads)
    }

    /// Review A47 fix 6 (a). `SIGTERMCancellation.signalCaught` stays true after `end()` until the next
    /// instance begins, and `execute(emit:)` runs with no scope of its own. A test process that caught a
    /// SIGTERM in an earlier class must not read a later failure as a cancel, which would turn the error
    /// into a cancelled run and write a `cancelled` record into the folder. The test posts its own SIGTERM,
    /// so it ignores SIGTERM first (review A54 fix 2) and puts the earlier action back last, and a post
    /// that outlives `end()` cannot end the unit process.
    func testAFailureAfterAnEarlierSIGTERMStaysAFailure() async throws {
        try await requireCompressor()
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        // Begins a new instance and ends it, so the flag reads false for the tests after this one.
        defer { SIGTERMCancellation {}.end() }
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-sigterm-earlier")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        let earlier = SIGTERMCancellation {}
        // The handler is out of reach from here on, as in SIGTERMCancellationTests, so the kernel drops the post and
        // only the note of it remains, which is all the flag needs.
        signal(SIGTERM, SIG_IGN)
        kill(getpid(), SIGTERM)
        XCTAssertTrue(SIGTERMCancellation.signalCaught, "an earlier instance caught a SIGTERM")
        earlier.end()
        XCTAssertTrue(SIGTERMCancellation.signalCaught, "the flag stays set after the instance ended")

        let outcome = await executeWithFailingSyncs(on: input)

        let error = try XCTUnwrap(outcome.error, "a sync that fails must fail the run")
        XCTAssertFalse(error is CancellationError, "the earlier SIGTERM did not cancel this run")
        XCTAssertTrue(error.localizedDescription.contains("sync"), "\(error.localizedDescription)")
        XCTAssertEqual(try names(in: root), ["reads.fastq"], "the original stays, with no output, no cancelled record, no sidecar and no hidden folder")
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads)
    }

    // MARK: - Where the output is staged (review A47 fix 6 (d), SWIFT 4)

    /// Runs the leaf in this process on `input` and returns, at the moment the staged output is synced, the entries
    /// of the temp folder `tmp` that hold it (a project's `.tmp` or the system temp folder, nil for none) and the
    /// hidden stage folders beside the input.
    private func stagingSeen(running input: URL, under tmp: URL?) async throws -> (underTmp: [String], besideInput: [String]) {
        let underTmp = IngestLog()
        let besideInput = IngestLog()
        let folder = input.deletingLastPathComponent()
        try await FastqIngestObservation.$observer.withValue({ step in
            guard step == .stageSynced else { return }
            if let tmp {
                for name in (try? FileManager.default.subpathsOfDirectory(atPath: tmp.path)) ?? [] where name.hasSuffix("/\(input.deletingPathExtension().lastPathComponent).fastq.gz") {
                    underTmp.append(name)
                }
            }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix(".lungfish-ingest-") {
                besideInput.append(name)
            }
        }) {
            try await self.execute([input.path, "--skip-clumpify", "--delete-originals", "--quiet"])
        }
        return (underTmp.all, besideInput.all)
    }

    /// The input of the one real flow sits in a `.lungfishfastq` bundle of a project. SWIFT 4 keeps stage files out
    /// of bundles, and a run that is killed outright leaves its folder where the project's cleanup finds it.
    func testABundleInAProjectStagesUnderTheProjectTmp() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-project-tmp")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Imports/Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let input = bundle.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)

        let seen = try await stagingSeen(running: input, under: project.appendingPathComponent(".tmp"))

        XCTAssertEqual(seen.underTmp.count, 1, "the staged output sits under the project's .tmp folder: \(seen.underTmp)")
        XCTAssertTrue(seen.underTmp.first?.hasPrefix("lungfish-ingest-") == true, "\(seen.underTmp)")
        XCTAssertEqual(seen.besideInput, [], "the bundle holds no .lungfish-ingest-* folder")
        XCTAssertEqual(try names(in: project.appendingPathComponent(".tmp")), [], "the work folder is gone when the run ends")
        XCTAssertEqual(
            try names(in: bundle).filter { !$0.hasPrefix(".lungfish-provenance") },
            ["provenance", "reads.fastq.gz", "reads.fastq.gz.lungfish-meta.json", "reads.fastq.gz.lungfish-provenance.json"],
            "the output is published into the bundle beside its records, and the original is gone"
        )
    }

    /// Points `TMPDIR` at `folder` while `body` runs, so the system temp folder is one of the test's own.
    private func withSystemTemp<T>(_ folder: URL, _ body: () async throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", folder.path, 1)
        defer {
            if let previous { setenv("TMPDIR", previous, 1) } else { unsetenv("TMPDIR") }
        }
        return try await body()
    }

    /// Anywhere else the hidden folder sits in the system temp folder when that folder shares the input's volume,
    /// with the marker the app's launch sweep reads (2.11 S8), and nothing stages beside the input.
    func testAFileOutsideAProjectStagesInTheSystemTempFolderOnItsVolume() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-no-project")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)

        let seen = try await withSystemTemp(systemTemp) { try await stagingSeen(running: input, under: systemTemp) }

        XCTAssertEqual(seen.underTmp.count, 1, "the staged output sits in the system temp folder: \(seen.underTmp)")
        XCTAssertTrue(seen.underTmp.first?.hasPrefix("lungfish-ingest-") == true, "\(seen.underTmp)")
        XCTAssertEqual(seen.besideInput, [], "nothing stages beside the input")
        XCTAssertEqual(try names(in: systemTemp), [], "the work folder is gone when the run ends")
        XCTAssertEqual(try names(in: root).filter { !$0.hasPrefix(".lungfish-provenance") }, ["T", "reads.fastq.gz", "reads.fastq.gz.lungfish-meta.json", "reads.fastq.gz.lungfish-provenance.json"])
    }

    /// S8's case for another volume, as an input on an ExFAT disk has. The hidden folder sits beside the input as it
    /// always did, so the publish stays a rename within one volume, and `exfat-tests.sh --simulate` runs this case
    /// with the fallback renames.
    func testAFileOnAnotherVolumeThanTheSystemTempFolderStagesBesideTheInput() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-other-volume")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let systemTemp = root.appendingPathComponent("T", isDirectory: true)
        let tempPath = systemTemp.resolvingSymlinksInPath().path + "/"

        let seen = try await withSystemTemp(systemTemp) {
            try await FastqIngestRun.$volumeReader.withValue({ url in
                url.resolvingSymlinksInPath().path.hasPrefix(tempPath) ? -1 : FastqIngestRun.volume(of: url)
            }) {
                try await stagingSeen(running: input, under: systemTemp)
            }
        }

        XCTAssertEqual(seen.underTmp, [], "nothing stages in a system temp folder on another volume")
        XCTAssertEqual(seen.besideInput.count, 1, "\(seen.besideInput)")
        XCTAssertEqual(try names(in: systemTemp), [], "the system temp candidate is removed")
        XCTAssertEqual(try names(in: root).filter { !$0.hasPrefix(".lungfish-provenance") }, ["T", "reads.fastq.gz", "reads.fastq.gz.lungfish-meta.json", "reads.fastq.gz.lungfish-provenance.json"])
    }

    // MARK: - The output is read once (review A47 fix 6 (e), SWIFT 5)

    /// The leaf reads the staged output once, before it publishes, while a cancel can still stop the read, and
    /// the record, the merge into the import record that stands and the output's sidecar all take that digest. A
    /// witness: the observer overwrites the published file when it is renamed into place, so a read after the
    /// publish would state the digest of the overwritten bytes.
    func testTheOutputIsReadOnceBeforePublishAndEveryRecordNamesThatDigest() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-read-once")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = try FastqIngestImportRecordFixture.makeBundle(in: root, reads: Self.reads)
        let output = fixture.folder.appendingPathComponent("Sample.fastq.gz")
        let published = IngestLog()
        try await FastqIngestObservation.$observer.withValue({ step in
            guard step == .renamed else { return }
            published.append(ProvenanceRecorder.sha256(of: output) ?? "unreadable")
            try? Data("overwritten after the publish".utf8).write(to: output)
        }) {
            try await self.execute([fixture.fastq.path, "--skip-clumpify", "--delete-originals", "--quiet"])
        }

        let staged = try XCTUnwrap(published.all.first)
        XCTAssertNotEqual(ProvenanceRecorder.sha256(of: output), staged, "the overwrite changed the published file")
        let record = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: fixture.folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        let sidecarRecord = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output))
        )
        // The root record's output, the import record's old outputs that the merge points at the gzip file, and the
        // import step's output, then the sidecar's own record.
        let named = (
            [record.output].compactMap { $0 } + record.outputs + record.files.filter { $0.role == .output }
                + record.steps.flatMap(\.outputs) + sidecarRecord.outputs
        ).filter { $0.path == output.path }
        XCTAssertGreaterThanOrEqual(named.count, 4, "the output is named by the record, its files, its steps and the sidecar: \(named.count)")
        for descriptor in named {
            XCTAssertEqual(descriptor.checksumSHA256, staged, "a record names the digest read before the publish")
        }
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

        try await execute([input.path, "--skip-clumpify", "--delete-originals", "--binning", "none", "--quiet"])

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

        try await execute([input.path, "--skip-clumpify", "--delete-originals", "--binning", "none", "--quiet"])

        XCTAssertEqual(try Data(contentsOf: input), Data([0x1f, 0x8b, 0x08, 0x00]), "the input is the output, so it stays")
        let ingestion = try XCTUnwrap(FASTQMetadataStore.load(for: input)?.ingestion)
        XCTAssertFalse(ingestion.isClumpified)
        XCTAssertEqual(try names(in: root).filter { !$0.hasPrefix(".lungfish-provenance") }, ["reads.fastq.gz", "reads.fastq.gz.lungfish-meta.json", "reads.fastq.gz.lungfish-provenance.json"])
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        XCTAssertEqual(envelope.files.first { $0.role == .input && $0.path == input.path }?.checksumSHA256, digest)
    }

    // MARK: - Where the app's route fails and the leaf does not (ruling on A47 M3, section 3)

    /// Item (b). When `auto` resolves clumping to `none` (an input above half the Java heap), the
    /// app's route compresses the file, removes the original, and then fails with "pipeline
    /// completed without clumpifying reads", leaving no sidecar and no record. The leaf warns,
    /// finishes, and records before it removes the original.
    func testClumpingResolvedToNoneWarnsAndRecordsBeforeRemoval() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-none")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let digest = try ProvenanceFileHasher.sha256(of: input)
        let output = root.appendingPathComponent("reads.fastq.gz")
        let resolution = ClumpingTool.default.resolve(estimatedInputBytes: Int64.max / 4)
        XCTAssertEqual(resolution.resolved, ClumpingTool.none, "an input far above the heap budget resolves to none")

        let probe = IngestRemovalMomentProbe(watching: [input]) {
            IngestPublishMoment.read(root: root, original: input, output: output)
        }
        FileManager.default.delegate = probe
        defer { FileManager.default.delegate = nil }
        let command = try FastqIngestSubcommand.parse([input.path, "--delete-originals", "--format", "json", "--quiet"])
        let lines = IngestLog()
        var run = FastqIngestRun(
            inputs: command.inputURLs(),
            options: command.runOptions(),
            command: command.replayArgv(),
            parameters: command.provenanceParameters(inputs: command.inputURLs()),
            defaults: FastqIngestSubcommand.provenanceDefaults,
            events: CLIEventEmitter(enabled: true, emit: { lines.append($0) }),
            clock: ProvenanceRunClock()
        )
        run.clumpingResolution = resolution

        let outcome = try await run.run()

        XCTAssertTrue(outcome.message.hasPrefix("Compressed (saved "), outcome.message)
        let events = try lines.all.map(object)
        let warning = events.first { $0["event"] as? String == "log" && $0["level"] as? String == "warning" }
        XCTAssertTrue((warning?["message"] as? String)?.contains("Clumping was skipped") == true, "\(lines.all)")
        XCTAssertEqual(
            probe.moments,
            [IngestPublishMoment(output: true, sidecar: true, record: true, original: true, recordedOriginalDigest: digest)],
            "the output, its sidecar and the record that names the original exist before it goes"
        )
        XCTAssertEqual(try XCTUnwrap(FASTQMetadataStore.load(for: output)?.ingestion).isClumpified, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }

    /// Item (c). The app's route saves the sidecar best-effort, logs a failed write and goes on to
    /// remove the original, so a row can finish with no sidecar. The leaf writes it with the
    /// throwing `write` before the record, so a sidecar that cannot be written stops the run with
    /// the original in place, no record, and the output already published for a rerun.
    func testAFailedSidecarWriteKeepsTheOriginal() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-sidecar-fails")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        let output = root.appendingPathComponent("reads.fastq.gz")
        // A folder holds the sidecar's name, so the write cannot replace it.
        try FileManager.default.createDirectory(
            at: FASTQMetadataStore.metadataURL(for: output), withIntermediateDirectories: true
        )

        let steps = IngestLog()
        do {
            try await FastqIngestObservation.$observer.withValue({ steps.append($0.rawValue) }) {
                try await self.execute([input.path, "--skip-clumpify", "--delete-originals", "--format", "json", "--quiet"])
            }
            XCTFail("a sidecar that cannot be written must fail the run")
        } catch {
            // Expected.
        }

        XCTAssertEqual(steps.all, ["stageSynced", "renamed", "folderSynced"], "the run stops at the sidecar")
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), Self.reads, "the original is as it was")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path),
            "no record is written for a run that did not finish"
        )
    }

    // MARK: - The record that stands

    /// A cancelled run leaves its own `cancelled` record where no other record stood (M2). A merge
    /// keeps the old record's status and exit status, so a later run replaces that record and does
    /// not join it, and the finished run reads completed (ruling on A47 M3, section 1).
    func testALaterRunReplacesItsOwnCancelledRecord() async throws {
        try await requireCompressor()
        let root = try TestTempDirectory.make(prefix: "fastq-ingest-own-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try Self.reads.write(to: input, atomically: true, encoding: .utf8)
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: FastqIngestRun.recordName,
            parameters: [:],
            toolName: "FASTQIngestionPipeline",
            toolVersion: "test",
            command: [CLICommandIdentity.executableName, "fastq", "ingest", input.path],
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.rawValue,
            wallTime: 0,
            stderr: nil,
            status: .cancelled,
            outputDirectory: root
        )
        let recordURL = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: recordURL)?.status, .cancelled)

        try await execute([input.path, "--skip-clumpify", "--quiet"])

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: recordURL))
        XCTAssertEqual(record.status, .completed, "a merge would have kept the cancelled status")
        XCTAssertEqual(record.exitStatus, 0)
        XCTAssertEqual(record.steps.filter { $0.toolName == "FASTQIngestionPipeline" }.count, 1, "the cancelled run's step is not joined")
    }

    func testTheOutputNameDropsTheMateSuffixAndAvoidsTheInputsOwnName() {
        let folder = URL(fileURLWithPath: "/work/project", isDirectory: true)
        let mate = FastqIngestRun.finalOutputURL(folder: folder, inputs: [folder.appendingPathComponent("SRR9_1.fastq")])
        XCTAssertEqual(mate.path, "/work/project/SRR9.fastq.gz")
        let same = FastqIngestRun.finalOutputURL(folder: folder, inputs: [folder.appendingPathComponent("reads.fastq.gz")])
        XCTAssertEqual(same.path, "/work/project/reads.clumped.fastq.gz", "an input that holds the output's name keeps it until the run ends")
    }
}
