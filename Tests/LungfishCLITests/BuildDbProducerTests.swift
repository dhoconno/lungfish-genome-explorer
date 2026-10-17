// BuildDbProducerTests.swift - Which files a build-db kraken2 run names as its own outputs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane B62 (SW4, R-PRODUCER, FXK2 follow-up 2, plan decision S9). `build-db kraken2` names as outputs of
// its step every per-read output, index and result sidecar it finds, whoever wrote it, and writes a sidecar beside each
// one that has none or a build-db one (`BuildDbCommand+Provenance.swift`, `buildDbOutputRecords`). A file it did not
// write so carried `lungfish build-db kraken2` as its producer, which a sidebar copy spreads (BIO 4, 6). M1 pinned that
// at the base in three `KnownDefect` tests. M2 names as outputs only `kraken2.sqlite` and the files the compaction wrote
// or rewrote, from `KrakenOutputCompactor.compact`'s return value, and every other matched file stays an input.
//
// Every case runs over a copy of `Tests/Fixtures/kraken2-mini`, three sample folders that each keep the raw per-read
// output `classification.kraken`, its report and `classification-result.json`, and no record.

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class BuildDbProducerTests: XCTestCase {
    private static let samples = ["SRR35517702", "SRR35517703", "SRR35517705"]
    private static let workflowName = "lungfish build-db kraken2"
    private static let rawOutput = "classification.kraken"
    private static let sidecar = ClassificationResult.sidecarFilename

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "BuildDbProducer")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - A run that wrote nothing in the sample folders

    /// `--no-cleanup` writes `kraken2.sqlite` and nothing in a sample folder, so its step names only the database as its
    /// output. Each kept raw output and result sidecar is an input of the step with the digest on disk, and no sidecar
    /// sits beside it. At the base the step named both as its outputs and wrote a `build-db kraken2` sidecar beside each.
    func testANoCleanupRunNamesOnlyTheDatabaseAsItsOutput() async throws {
        let result = try copyOfKraken2Mini()

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "--no-cleanup", "-q"]).run()

        let build = try buildStep(of: result)
        XCTAssertEqual(names(build.outputs, in: result), Self.outputs([]))
        assertNamedAsInputsOnly(Self.samples.flatMap { ["\($0)/\(Self.rawOutput)", "\($0)/\(Self.sidecar)"] }, in: result)
    }

    /// A rerun with `--force` over a result an earlier run compacted writes no file in a sample folder, so its step names
    /// only the database as its output, and the sidecar beside each gzip copy, index and result sidecar is still the
    /// earlier run's, which wrote them. At the base the rerun named them as its outputs and replaced those sidecars.
    func testAForcedRerunKeepsTheEarlierRunAsTheProducerOfWhatItWrote() async throws {
        let result = try copyOfKraken2Mini()
        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()
        let first = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result)).id

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "--force", "-q"]).run()

        let second = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        XCTAssertNotEqual(second.id, first)
        XCTAssertEqual(names(try buildStep(of: result).outputs, in: result), Self.outputs([]))
        for name in Self.compactedOutputs where name != "kraken2.sqlite" {
            let file = result.appendingPathComponent(name)
            XCTAssertEqual(sidecarRecord(of: file)?.id, first, "\(name) names the earlier run, which wrote it, as its producer")
            XCTAssertTrue(
                try buildStep(of: result).inputs.contains { names([$0], in: result) == [name] && $0.checksumSHA256 == ProvenanceRecorder.sha256(of: file) },
                "the rerun names \(name) as an input with the digest on disk"
            )
        }
        XCTAssertEqual(sidecarRecord(of: result.appendingPathComponent("kraken2.sqlite"))?.id, second.id, "the rerun wrote the database")
    }

    /// Each sample folder holds the classifier's record, which names the raw output and the result sidecar, so the
    /// cleanup keeps every folder as it is (2.10 FXA2). The run's step names only the database as its output, and both
    /// files of each folder are inputs with the digest on disk and no sidecar. At the base the step named them as its
    /// outputs and wrote a `build-db kraken2` sidecar beside each.
    func testAFolderTheCleanupKeptNamesItsFilesAsInputs() async throws {
        let result = try copyOfKraken2Mini()
        try writeClassifierRecords(in: result)

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.appendingPathComponent("SRR35517702/\(Self.rawOutput)").path))
        XCTAssertEqual(names(try buildStep(of: result).outputs, in: result), Self.outputs([]))
        assertNamedAsInputsOnly(Self.samples.flatMap { ["\($0)/\(Self.rawOutput)", "\($0)/\(Self.sidecar)"] }, in: result)
    }

    // MARK: - A run that compacts

    /// A compacting run names as outputs the database and, in each sample folder, the gzip copy and its index that the
    /// compaction wrote and the result sidecar it rewrote, each with a `build-db kraken2` sidecar.
    func testACompactingRunNamesTheGzipCopyAndItsIndexAsOutputs() async throws {
        let result = try copyOfKraken2Mini()

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        let build = try buildStep(of: result)
        XCTAssertEqual(names(build.outputs, in: result), Self.compactedOutputs)
        XCTAssertEqual(
            build.outputs.filter { $0.role == .index }.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            Array(repeating: "classification.kraken.gz.idx.sqlite", count: Self.samples.count), "the indexes are named as indexes"
        )
        for output in build.outputs {
            let sidecar = sidecarRecord(of: URL(fileURLWithPath: output.path))
            XCTAssertEqual(sidecar?.id, record.id, "\(output.path) has the run's sidecar")
            XCTAssertEqual(output.checksumSHA256, ProvenanceRecorder.sha256(of: URL(fileURLWithPath: output.path)), output.path)
        }
        // The run's step names each file the compaction wrote as the compaction's step names it, hashed once (SWIFT 5),
        // so the run level names each file once. At the base it named each gzip copy and index twice.
        for written in record.steps.filter({ ["gzip", "lungfish-kraken2-index"].contains($0.toolName) }).flatMap(\.outputs) {
            XCTAssertTrue(build.outputs.contains(written), "the run's step names \(written.path) as the compaction does")
        }
        for (label, files) in [("outputs", record.outputs), ("files", record.files)] {
            let named = files.map { "\($0.role.rawValue) \(names([$0], in: result).joined())" }
            XCTAssertEqual(named.count, Set(named).count, "the run level's \(label) name each file once, \(named.sorted())")
        }
    }

    /// The gzip step the compacting run records, byte for byte, in a folder whose name holds a space and a quote (plan
    /// decision S9, `BuildDbCommand+Kraken2Core.swift`, `compactionSteps`).
    func testTheCompactingRunRecordsTheGzipCommandByteForByte() async throws {
        let result = try copyOfKraken2Mini()
        let quoted = result.appendingPathComponent("SRR35517705 it's", isDirectory: true)
        try FileManager.default.moveItem(at: result.appendingPathComponent("SRR35517705", isDirectory: true), to: quoted)

        try await BuildDbCommand.Kraken2Subcommand.parse([result.path, "-q"]).run()

        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result))
        let suffix = "/kraken2/SRR35517705 it's/classification.kraken"
        let gzip = try XCTUnwrap(record.steps.first { $0.toolName == "gzip" && $0.inputs.first?.path.hasSuffix(suffix) == true })
        let raw = try XCTUnwrap(gzip.inputs.first?.path)
        let prefix = String(raw.dropLast(suffix.count))
        XCTAssertFalse(prefix.contains("'"), prefix)
        XCTAssertEqual(gzip.toolVersion, "system")
        XCTAssertEqual(gzip.argv, [
            "/bin/sh", "-c",
            "/usr/bin/gzip -c '\(prefix)/kraken2/SRR35517705 it'\\''s/classification.kraken' > '\(prefix)/kraken2/SRR35517705 it'\\''s/classification.kraken.gz'",
        ])
        XCTAssertEqual(gzip.outputs.map(\.path), [raw + ".gz"])
        let index = try XCTUnwrap(record.steps.first { $0.toolName == "lungfish-kraken2-index" && $0.inputs == gzip.inputs })
        XCTAssertEqual(index.argv, [
            CLICommandIdentity.executableName, "internal", "kraken2-index", "--classified-only", raw, raw + ".gz.idx.sqlite",
        ])
    }

    // MARK: - Each sample's record of its result sidecar

    /// FXK2 follow-up 2, rechecked at the base. A sample folder whose classifier record names the result sidecar is kept
    /// as it is (2.10 FXA2), so that record still states the digest the sidecar had before the run, which is the one on
    /// disk. In a folder with no such record the cleanup rewrites the sidecar in place, and the record `build-db` writes
    /// beside it states the digest on disk, with a removal step that names the bytes it had before the rewrite (2.10 B34).
    func testEachSampleRecordStatesTheDigestOfItsResultSidecarOnDisk() async throws {
        let kept = try copyOfKraken2Mini(named: "kept")
        try writeClassifierRecords(in: kept)
        let before = try digests(of: Self.sidecar, in: kept)

        try await BuildDbCommand.Kraken2Subcommand.parse([kept.path, "-q"]).run()

        for sample in Self.samples {
            let file = kept.appendingPathComponent("\(sample)/\(Self.sidecar)")
            let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: file.deletingLastPathComponent()))
            XCTAssertEqual(record.workflowName, "Metagenomics Classification", sample)
            let stated = (record.files + record.outputs).filter { $0.path == file.path }.compactMap(\.checksumSHA256)
            XCTAssertFalse(stated.isEmpty, "\(sample)'s classifier record names its result sidecar")
            XCTAssertEqual(Set(stated), Set([before[sample]].compactMap { $0 }), "\(sample)'s classifier record states the digest the sidecar had")
            XCTAssertEqual(ProvenanceRecorder.sha256(of: file), before[sample], "\(sample)'s result sidecar is as it was")
        }

        let compacted = try copyOfKraken2Mini(named: "compacted")
        let replaced = try digests(of: Self.sidecar, in: compacted)

        try await BuildDbCommand.Kraken2Subcommand.parse([compacted.path, "-q"]).run()

        for sample in Self.samples {
            let file = compacted.appendingPathComponent("\(sample)/\(Self.sidecar)")
            let onDisk = try XCTUnwrap(ProvenanceRecorder.sha256(of: file))
            XCTAssertNotEqual(onDisk, replaced[sample], "\(sample)'s result sidecar was rewritten in place")
            let record = try XCTUnwrap(sidecarRecord(of: file), "\(sample)'s result sidecar has a record")
            XCTAssertEqual(record.outputs.map(\.checksumSHA256), [onDisk], "\(sample)'s record states the digest on disk")
            let removal = try XCTUnwrap(record.steps.first { $0.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation) })
            XCTAssertTrue(
                removal.inputs.contains { names([$0], in: compacted) == ["\(sample)/\(Self.sidecar)"] && $0.checksumSHA256 == replaced[sample] },
                "\(sample)'s record names the bytes the rewrite replaced"
            )
        }
    }

    // MARK: - Helpers

    /// The outputs of a run that compacted every sample folder of kraken2-mini, sorted as `names` sorts them.
    private static let compactedOutputs = outputs([sidecar, "classification.kraken.gz", "classification.kraken.gz.idx.sqlite"])

    /// `kraken2.sqlite` and the files named `perSample` in each sample folder, sorted as `names` sorts them.
    private static func outputs(_ perSample: [String]) -> [String] {
        (["kraken2.sqlite"] + samples.flatMap { sample in perSample.map { "\(sample)/\($0)" } }).sorted()
    }

    private func copyOfKraken2Mini(named name: String = "kraken2") throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/kraken2-mini", isDirectory: true)
        let result = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: result)
        return result
    }

    /// The record the app writes for a Kraken2 result, from its sidecar, in each sample folder, as FXA2's tests write it.
    /// It names the report, the raw output and the result sidecar, and `build-db` may not replace it.
    private func writeClassifierRecords(in result: URL) throws {
        for sample in Self.samples {
            let folder = result.appendingPathComponent(sample, isDirectory: true)
            try ProvenanceWriter().write(ClassificationProvenanceReconstructor.reconstructEnvelope(resultDirectory: folder), to: folder)
        }
    }

    private func buildStep(of result: URL) throws -> ProvenanceStep {
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: result), "the result folder's record")
        return try XCTUnwrap(record.steps.last { $0.toolName == Self.workflowName }, "the run's own step")
    }

    /// Each of `relativePaths` in `result` is an input of the run's step with the digest on disk, is not among its outputs
    /// or the run level's, and has no sidecar beside it (BIO 6, added check 3).
    private func assertNamedAsInputsOnly(_ relativePaths: [String], in result: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard let record = ProvenanceRecorder.loadEnvelope(from: result), let build = try? buildStep(of: result) else {
            return XCTFail("the result folder holds the run's record", file: file, line: line)
        }
        for relativePath in relativePaths {
            let url = result.appendingPathComponent(relativePath)
            let digest = ProvenanceRecorder.sha256(of: url)
            XCTAssertNotNil(digest, relativePath, file: file, line: line)
            XCTAssertTrue(
                build.inputs.contains { names([$0], in: result) == [relativePath] && $0.checksumSHA256 == digest },
                "the run names \(relativePath) as an input with the digest on disk", file: file, line: line
            )
            XCTAssertFalse(
                (build.outputs + record.outputs).contains { names([$0], in: result) == [relativePath] },
                "the run names \(relativePath), which it did not write, as an output", file: file, line: line
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: url).path),
                "a sidecar sits beside \(relativePath), which the run did not write", file: file, line: line
            )
        }
    }

    private func sidecarRecord(of file: URL) -> ProvenanceEnvelope? {
        ProvenanceRecorder.loadEnvelope(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: file))
    }

    private func digests(of name: String, in result: URL) throws -> [String: String] {
        var digests: [String: String] = [:]
        for sample in Self.samples {
            digests[sample] = try XCTUnwrap(ProvenanceRecorder.sha256(of: result.appendingPathComponent("\(sample)/\(name)")))
        }
        return digests
    }

    /// Each file as `<sample>/<name>`, or `<name>` for a file of the result folder, with its folder resolved so that
    /// /var/folders and /private/var/folders are one place, sorted.
    private func names(_ files: [ProvenanceFileDescriptor], in result: URL) -> [String] {
        let base = result.resolvingSymlinksInPath().path + "/"
        return files.map { file in
            let url = URL(fileURLWithPath: file.path)
            let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        }
        .sorted()
    }
}
