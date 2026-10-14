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
import os
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
    /// `classification.kraken` (Phase 2.10 lane B34, row 268, and follow-up 1 of the A39 review). The classifier tests'
    /// `assertEveryNamedFileIsKeptOrRemoved` walks the steps only. A step keeps a file as it was when the step ran and a
    /// removal step names what went, but rule B3 lets no removal step excuse the run level, which names only what is on
    /// disk. So every file the run level names is there, and none has a path and digest that a removal step names.
    func testKraken2CleanupRunLevelNamesOnlyFilesThatAreOnDisk() async throws {
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
        let bytesRemoved = Set(removal.inputs.compactMap { named in
            named.checksumSHA256.map { "\(resolved(named.path)) \($0)" }
        })
        var withDigest = 0
        for named in runLevel {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: named.path), "the run level names \(named.path), which is gone"
            )
            guard let digest = named.checksumSHA256 else { continue }
            withDigest += 1
            XCTAssertFalse(
                bytesRemoved.contains("\(resolved(named.path)) \(digest)"),
                "the run level names \(named.path) with the digest of bytes a removal step names"
            )
        }
        XCTAssertGreaterThan(withDigest, 0, "the run level names files with their digests")
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
    /// digest a step of the record states for a file that is still there equals the file's, or a removal step names
    /// those old bytes, as `RecordedRemovalStep` says of a file that a run rewrote in place. The run level, which
    /// names only what is on disk (B3, follow-up 1 of the A39 review), has no such excuse. It names each file with
    /// the digest the file has now and never the bytes a removal step names.
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

        // A step keeps a file as it was when the step ran, so a removal step excuses a step's naming of the replaced
        // bytes (P1).
        var compared = 0
        for named in record.steps.flatMap({ $0.inputs + $0.outputs }) {
            guard let digest = named.checksumSHA256, FileManager.default.fileExists(atPath: named.path) else { continue }
            compared += 1
            XCTAssertTrue(
                digest == ProvenanceRecorder.sha256(of: URL(fileURLWithPath: named.path))
                    || namedByARemoval.contains("\(resolved(named.path)) \(digest)"),
                "\(named.path) is stated with a digest it no longer has, and no removal step names those bytes"
            )
        }
        XCTAssertGreaterThan(compared, 0, "the steps state digests of files that are there")

        // The run level names only what is on disk (B3), so no removal step excuses it. Every file it names is there
        // with the digest it has now, and none has a path and digest that a removal step names.
        let runLevel = record.files + record.outputs + [record.output].compactMap { $0 }
        var comparedAtRunLevel = 0
        for named in runLevel {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: named.path), "the run level names \(named.path), which is gone"
            )
            guard let digest = named.checksumSHA256 else { continue }
            comparedAtRunLevel += 1
            XCTAssertFalse(
                namedByARemoval.contains("\(resolved(named.path)) \(digest)"),
                "the run level names \(named.path) with the digest of bytes a removal step names"
            )
            XCTAssertEqual(
                digest, ProvenanceRecorder.sha256(of: URL(fileURLWithPath: named.path)),
                "the run level states \(named.path) with a digest it no longer has"
            )
        }
        XCTAssertGreaterThan(comparedAtRunLevel, 0, "the run level states digests of files that are there")
    }

    // MARK: - A record the classifier wrote (Phase 2.10 lane FXA2)

    /// ARCH's ruling on A45 M3, section 4 (the rest of 2.8 row 268, follow-up 2 of the A39 review and BIO's Q2). The
    /// classifier's record names the per-read output it kept and the result sidecar, each with its digest. The cleanup
    /// removed the first and rewrote the second in place, and `build-db` may not replace that record, so it named a file
    /// that was gone and bytes the file no longer had. A folder whose record names either of them keeps both, and a folder
    /// with no record compacts as before.
    func testKraken2CleanupChangesNoFileTheClassifierRecordNames() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalClassifierRecord")
        defer { TestTempDirectory.cleanup(root) }
        let result = try copyOfKraken2Mini(in: root)
        let recorded = result.appendingPathComponent("SRR35517702", isDirectory: true)
        try writeClassifierRecord(in: recorded, naming: [Self.rawOutput, Self.sidecar])
        let rawBefore = try digest(recorded.appendingPathComponent(Self.rawOutput))
        let sidecarBefore = try digest(recorded.appendingPathComponent(Self.sidecar))
        let recordBefore = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: recorded))

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        // The record is still the classifier's, and every file it names exists with the digest it states.
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: recorded))
        XCTAssertEqual(record.id, recordBefore.id, "build-db leaves the classifier's record as it was")
        XCTAssertEqual(record.workflowName, Self.classifierWorkflowName)
        XCTAssertGreaterThan(assertEveryNamedFileIsAsStated(record, "the classifier's record"), 0)
        // So the raw output and the sidecar hold the bytes they held, and no copy was made beside a raw output that stays.
        XCTAssertEqual(try digest(recorded.appendingPathComponent(Self.rawOutput)), rawBefore)
        XCTAssertEqual(try digest(recorded.appendingPathComponent(Self.sidecar)), sidecarBefore)
        assertNoCompactedCopy(in: recorded)
        // The folders with no record compact as before.
        for name in ["SRR35517703", "SRR35517705"] {
            assertCompacted(result.appendingPathComponent(name, isDirectory: true))
        }
        // The build's own removal step names nothing of the folder it left alone.
        let build = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        let removal = try XCTUnwrap(build.steps.first { $0.toolName == ClassificationPipeline.kraken2OutputRemovalToolName })
        XCTAssertFalse(removal.inputs.contains { $0.path.contains("/SRR35517702/") }, "the removal step names a file of the kept folder")
        XCTAssertTrue(removal.inputs.contains { $0.path.hasSuffix("/SRR35517703/classification.kraken") }, "the compacted folders are named")
    }

    /// A record that names only the raw output, or only the sidecar, keeps both files too. The compaction removes the
    /// first and rewrites the second together, so it runs whole or not at all.
    func testKraken2CleanupKeepsBothFilesWhenTheRecordNamesOnlyOneOfThem() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalOneOfThem")
        defer { TestTempDirectory.cleanup(root) }
        let result = try copyOfKraken2Mini(in: root)
        let namesRawOutput = result.appendingPathComponent("SRR35517702", isDirectory: true)
        let namesSidecar = result.appendingPathComponent("SRR35517703", isDirectory: true)
        try writeClassifierRecord(in: namesRawOutput, naming: [Self.rawOutput])
        try writeClassifierRecord(in: namesSidecar, naming: [Self.sidecar])
        var before: [URL: [String]] = [:]
        for folder in [namesRawOutput, namesSidecar] {
            before[folder] = [try digest(folder.appendingPathComponent(Self.rawOutput)), try digest(folder.appendingPathComponent(Self.sidecar))]
        }

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        for folder in [namesRawOutput, namesSidecar] {
            let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder))
            XCTAssertEqual(record.workflowName, Self.classifierWorkflowName, folder.lastPathComponent)
            XCTAssertGreaterThan(assertEveryNamedFileIsAsStated(record, "the record of \(folder.lastPathComponent)"), 0)
            XCTAssertEqual(
                [try digest(folder.appendingPathComponent(Self.rawOutput)), try digest(folder.appendingPathComponent(Self.sidecar))],
                before[folder], "\(folder.lastPathComponent) keeps the raw output and the sidecar as they were"
            )
            assertNoCompactedCopy(in: folder)
        }
        assertCompacted(result.appendingPathComponent("SRR35517705", isDirectory: true))
    }

    /// One information line for each folder the cleanup keeps, which says why (UX 2 of the expert panel). It is text
    /// and not a warning, so a run that kept a folder does not end Completed with Warnings.
    func testKraken2CleanupSaysOnceInAnInformationLineWhyItKeptAFolder() async throws {
        let root = try TestTempDirectory.make(prefix: "BuildDbRecordedRemovalKeptLine")
        defer { TestTempDirectory.cleanup(root) }
        let result = try copyOfKraken2Mini(in: root)
        try writeClassifierRecord(in: result.appendingPathComponent("SRR35517702", isDirectory: true), naming: [Self.rawOutput, Self.sidecar])
        try writeClassifierRecord(in: result.appendingPathComponent("SRR35517703", isDirectory: true), naming: [Self.sidecar])
        let lines = BuildDbLines()

        _ = try await BuildDbCommand.Kraken2Subcommand.buildDatabase(
            in: result, options: BuildDbRunOptions(globalOptions: try GlobalOptions.parse([])), events: lines.sink
        )

        // Each line names the folder and the files its record names, so the second says only the sidecar.
        let kept = lines.text.filter { $0.hasPrefix("Kept ") }
        XCTAssertEqual(kept, [
            "Kept SRR35517702 as it is because its provenance record names classification.kraken and classification-result.json.",
            "Kept SRR35517703 as it is because its provenance record names classification-result.json.",
        ], "one line for each kept folder and none for the folder that compacts, \(lines.text)")
        XCTAssertEqual(lines.warnings, [], "no information line becomes a warning")
    }

    private static let classifierWorkflowName = "Metagenomics Classification"
    private static let rawOutput = "classification.kraken"
    private static let sidecar = ClassificationResult.sidecarFilename

    private func copyOfKraken2Mini(in root: URL) throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent("kraken2", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        return result
    }

    private func digest(_ url: URL) throws -> String {
        try XCTUnwrap(ProvenanceRecorder.sha256(of: url), url.path)
    }

    /// The record the classifier leaves in a sample folder, as far as these tests read it. It is another workflow's
    /// record than `lungfish build-db kraken2`, so the build may not replace it. It names `files` of the folder at run
    /// level and in the step that wrote them, each with its digest.
    private func writeClassifierRecord(in folder: URL, naming files: [String]) throws {
        let urls = files.map { folder.appendingPathComponent($0) }
        let descriptors = try urls.map { try ProvenanceFileDescriptor.file(url: $0, role: .output) }
        var builder = ProvenanceRunBuilder(
            workflowName: Self.classifierWorkflowName, workflowVersion: "test", toolName: "kraken2", toolVersion: "2.17.1"
        )
        .argv(["lungfish-cli", "kraken2", "classify", folder.path])
        .runtime(ProvenanceRuntimeIdentity())
        for url in urls { builder = try builder.output(url, role: .output) }
        let record = try builder
            .step(ProvenanceStep(
                toolName: "kraken2", toolVersion: "2.17.1", argv: ["kraken2", "--db", "Viral"], outputs: descriptors,
                exitStatus: 0, wallTimeSeconds: 1
            ))
            .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter().write(record, to: folder)
    }

    /// Asserts that each file the record names, at run level and in its steps, exists and holds the bytes the record
    /// states. Returns how many digests it compared.
    @discardableResult
    private func assertEveryNamedFileIsAsStated(_ record: ProvenanceEnvelope, _ label: String) -> Int {
        var compared = 0
        let named = record.files + record.outputs + [record.output].compactMap { $0 } + record.steps.flatMap { $0.inputs + $0.outputs }
        for file in named {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(label) names \(file.path), which is gone")
            guard let stated = file.checksumSHA256 else { continue }
            compared += 1
            XCTAssertEqual(
                ProvenanceRecorder.sha256(of: URL(fileURLWithPath: file.path)), stated,
                "\(label) states a digest that \(file.path) no longer has"
            )
        }
        return compared
    }

    private func assertNoCompactedCopy(in folder: URL, file: StaticString = #filePath, line: UInt = #line) {
        for copy in ["classification.kraken.gz", "classification.kraken.gz.idx.sqlite"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(copy).path),
                "\(copy) was made beside a raw output that stays", file: file, line: line
            )
        }
    }

    /// What a cleanup leaves in a folder it compacted: the gzip copy, and the sidecar naming it.
    private func assertCompacted(_ folder: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.rawOutput).path), folder.lastPathComponent, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("classification.kraken.gz").path), folder.lastPathComponent, file: file, line: line)
        XCTAssertEqual(try? ClassificationResult.load(from: folder).outputURL.pathExtension, "gz", folder.lastPathComponent, file: file, line: line)
    }
}

/// The lines of one `build-db` run by the channel they arrived on, text and warnings.
private final class BuildDbLines: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: (text: [String](), warnings: [String]()))

    var sink: BuildDbEventSink {
        BuildDbEventSink(
            progress: { _, _ in },
            text: { line in self.storage.withLock { $0.text.append(line) } },
            textWarning: { line in self.storage.withLock { $0.warnings.append(line) } },
            warning: { line in self.storage.withLock { $0.warnings.append(line) } }
        )
    }

    var text: [String] { storage.withLock { $0.text } }
    var warnings: [String] { storage.withLock { $0.warnings } }
}
