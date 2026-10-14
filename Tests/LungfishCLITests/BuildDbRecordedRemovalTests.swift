// BuildDbRecordedRemovalTests.swift - build-db kraken2 records the compaction it makes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row 423 and panel decision P1 of Phase 2.8 (docs/plans/2026-10-11-phase-2-8.md). The classifier's
// record names the per-read output it wrote with its digest. When `build-db kraken2` compacts that
// output, the run records the index and gzip steps the classifier records for its own compaction,
// and one removal step that names each removed file with the digest it had, so no record names
// a file that is gone without a step that says why.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbRecordedRemovalTests: XCTestCase {
    func testKraken2CleanupRecordsItsCompactionAndRemoval() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemoval")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent("kraken2", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        let sample = result.appendingPathComponent("SRR35517702", isDirectory: true)
        let raw = sample.appendingPathComponent("classification.kraken")
        try Data("C\tread-1\t12345\t150\t12345:150\nU\tread-2\t0\t150\t0:150\n".utf8).write(to: raw)
        try Data("kraken index".utf8).write(to: sample.appendingPathComponent("classification.kraken.idx.sqlite"))

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        func step(_ toolName: String) throws -> ProvenanceStep {
            try XCTUnwrap(record.steps.first { $0.toolName == toolName }, toolName)
        }
        func names(_ files: [ProvenanceFileDescriptor]) -> [String] {
            files.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        }
        let gzip = try step("gzip")
        let index = try step("lungfish-kraken2-index")
        XCTAssertEqual(names(gzip.inputs), ["classification.kraken"])
        XCTAssertNotNil(gzip.inputs.first?.checksumSHA256, "The steps read the per-read output with its digest")
        XCTAssertEqual(index.inputs, gzip.inputs, "The per-read output is hashed once")
        XCTAssertEqual(names(gzip.outputs), ["classification.kraken.gz"])
        XCTAssertEqual(names(index.outputs), ["classification.kraken.gz.idx.sqlite"])

        let removal = try step(ClassificationPipeline.kraken2OutputRemovalToolName)
        XCTAssertEqual(removal.resolvedOptions["operation"], .string(RecordedRemovalStep.operation))
        // kraken2-mini keeps the raw per-read output of each of its three samples. The files that are gone come
        // first. The sidecar of each sample follows, which the compaction rewrote in place (2.10 B34 review fix 5).
        XCTAssertEqual(removal.inputs.map { "\(URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent)/"
            + URL(fileURLWithPath: $0.path).lastPathComponent }, [
            "SRR35517702/classification.kraken", "SRR35517702/classification.kraken.idx.sqlite",
            "SRR35517703/classification.kraken", "SRR35517705/classification.kraken",
            "SRR35517702/classification-result.json", "SRR35517703/classification-result.json",
            "SRR35517705/classification-result.json",
        ])
        XCTAssertEqual(removal.inputs.first, gzip.inputs.first, "The removal names the bytes the compaction read")
        XCTAssertNotNil(removal.inputs[1].checksumSHA256, "The old index is named with its digest")
        XCTAssertEqual(removal.outputs, [])
        for named in removal.inputs {
            let rewritten = URL(fileURLWithPath: named.path).lastPathComponent == ClassificationResult.sidecarFilename
            XCTAssertNotNil(named.checksumSHA256, "\(named.path) is named with the digest it had")
            XCTAssertEqual(
                FileManager.default.fileExists(atPath: named.path), rewritten,
                rewritten ? "\(named.path) was rewritten in place" : "\(named.path) is gone"
            )
        }
        XCTAssertEqual(record.steps.last?.toolName, "lungfish build-db kraken2", "The run's own step comes last")
    }

    /// The run level of the record, `files`, `outputs` and `output`, read from the envelope after the cleanup removed
    /// `classification.kraken` (Phase 2.10 lane B34, row 268). `assertEveryNamedFileIsKeptOrRemoved` of the classifier
    /// tests walks the steps only. Every file the run level names is there, or the removal step names it, so the record
    /// never advertises a file that is gone without saying why.
    func testKraken2CleanupRunLevelNamesNoGoneFileWithoutARemovalStep() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalRunLevel")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent("kraken2", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        let sample = result.appendingPathComponent("SRR35517702", isDirectory: true)
        let raw = sample.appendingPathComponent("classification.kraken")
        try Data("C\tread-1\t12345\t150\t12345:150\nU\tread-2\t0\t150\t0:150\n".utf8).write(to: raw)

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        let removal = try XCTUnwrap(record.steps.first { $0.toolName == ClassificationPipeline.kraken2OutputRemovalToolName })
        // A removed file cannot be resolved, so its folder is, and /var/folders and /private/var/folders are one place.
        func resolved(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        let removed = Set(removal.inputs.map { resolved($0.path) })
        XCTAssertTrue(removed.contains(resolved(raw.path)), "the cleanup removed the per-read output and says so")
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        let runLevel = record.files + record.outputs + [record.output].compactMap { $0 }
        XCTAssertFalse(runLevel.isEmpty)
        for named in runLevel where !removed.contains(resolved(named.path)) {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: named.path), "the run level names \(named.path), which is gone with no removal step"
            )
        }
        XCTAssertFalse(
            record.outputs.contains { removed.contains(resolved($0.path)) && !FileManager.default.fileExists(atPath: $0.path) },
            "an output the run removed is not an output of the record, unless the run rewrote it in place"
        )
    }

    func testKraken2CleanupThatCompactsNothingRecordsNoRemoval() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalNone")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent("kraken2", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        for sample in ["SRR35517702", "SRR35517703", "SRR35517705"] {
            let raw = result.appendingPathComponent("\(sample)/classification.kraken")
            if FileManager.default.fileExists(atPath: raw.path) { try FileManager.default.removeItem(at: raw) }
        }

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        XCTAssertEqual(record.steps.map(\.toolName), ["lungfish build-db kraken2"])
    }

    /// Phase 2.10 lane B34, review fix 5. A cleanup over a result whose sidecar holds a fragment composition and a
    /// read pairing contract beside a raw `classification.kraken` (which a failed compaction leaves, and a kept raw
    /// output now also leaves) rewrites the sidecar to name the gzip copy. The rewrite keeps both facts, because a
    /// result without them reads as one that may have counted each mate as its own read (READ-PAIRING.md).
    func testKraken2CleanupKeepsTheReadPairingFactsOfTheSidecar() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalPairing")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent("kraken2", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        let sample = result.appendingPathComponent("SRR35517702", isDirectory: true)
        try Data("C\tread-1\t12345\t150\t12345:150\nU\tread-2\t0\t150\t0:150\n".utf8)
            .write(to: sample.appendingPathComponent("classification.kraken"))
        let composition = ClassificationFragmentComposition(
            pairedFragments: 2, mergedReads: 1, orphanReads: 0, singleEndReads: 0
        )
        let stored = try ClassificationResult.load(from: sample)
        try ClassificationResult(
            config: stored.config, tree: stored.tree, reportURL: stored.reportURL, outputURL: stored.outputURL,
            brackenURL: stored.brackenURL, profileOutcome: stored.profileOutcome, runtime: stored.runtime,
            toolVersion: stored.toolVersion, provenanceId: stored.provenanceId, fragmentComposition: composition,
            readPairingContract: ClassificationResult.currentReadPairingContract
        ).save(to: sample)
        let before = try ClassificationResult.load(from: sample)
        XCTAssertEqual(before.fragmentComposition, composition)
        XCTAssertEqual(before.readPairingContract, ClassificationResult.currentReadPairingContract)
        XCTAssertEqual(before.outputURL.lastPathComponent, "classification.kraken")

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        let after = try ClassificationResult.load(from: sample)
        XCTAssertEqual(after.outputURL.pathExtension, "gz", "the rewrite names the gzip copy")
        XCTAssertEqual(after.fragmentComposition, before.fragmentComposition, "the rewrite keeps the fragment composition")
        XCTAssertEqual(after.readPairingContract, before.readPairingContract, "and the read pairing contract")
    }

    /// Phase 2.10 lane B34, review fix 5 item 2. The cleanup rewrites `classification-result.json` in place to name the
    /// gzip copy, so the digest this record states for it from before the run is not the one the file has now. Every
    /// digest the record states for a file that is still there equals the file's, or a removal step names those old
    /// bytes, as `RecordedRemovalStep` says of a file that a run rewrote in place.
    func testKraken2CleanupNamesTheBytesItReplacedInTheSidecar() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalRewrite")
        defer { TestTempDirectory.cleanup(root) }
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent("kraken2", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        let sample = result.appendingPathComponent("SRR35517702", isDirectory: true)
        let sidecar = sample.appendingPathComponent(ClassificationResult.sidecarFilename)
        let replacedDigest = try XCTUnwrap(ProvenanceRecorder.sha256(of: sidecar))

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        XCTAssertNotEqual(ProvenanceRecorder.sha256(of: sidecar), replacedDigest, "the cleanup rewrote the sidecar in place")
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        // A removed file cannot be resolved, so its folder is, and /var/folders and /private/var/folders are one place.
        func resolved(_ path: String) -> String {
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        }
        let removals = record.steps.filter { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) }
        let namedByARemoval = Set(removals.flatMap(\.inputs).compactMap { named in
            named.checksumSHA256.map { "\(resolved(named.path)) \($0)" }
        })
        XCTAssertTrue(
            namedByARemoval.contains("\(resolved(sidecar.path)) \(replacedDigest)"),
            "a removal step names the bytes the rewrite replaced"
        )

        let stated = record.steps.flatMap { $0.inputs + $0.outputs } + record.files + record.outputs
            + [record.output].compactMap { $0 }
        var compared = 0
        for named in stated {
            guard let digest = named.checksumSHA256, FileManager.default.fileExists(atPath: named.path) else { continue }
            compared += 1
            XCTAssertTrue(
                digest == ProvenanceRecorder.sha256(of: URL(fileURLWithPath: named.path))
                    || namedByARemoval.contains("\(resolved(named.path)) \(digest)"),
                "\(named.path) is stated with a digest it no longer has, and no removal step names those bytes"
            )
        }
        XCTAssertGreaterThan(compared, 0, "the record states digests of files that are there")
    }
}
