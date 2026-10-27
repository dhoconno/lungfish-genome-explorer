// FastqExportReadsCommandTests.swift - lungfish-cli fastq export reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38 M2, ARCH ruling on the export shape 1.1 row B4 and 1.4, BIO 1, 3 and 6. The leaf writes a
// plain bundle's file, several source chunks joined and a derived bundle materialized, records the CLI identity with
// the inputs the in-app writer named, refuses before it writes, and parses the arguments the sidebar builds.

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class FastqExportReadsCommandTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("FastqExportReads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let reads = "@r1\nACGT\n+\nIIII\n@r2\nTTGA\n+\nIIII\n"

    private func plainBundle() throws -> URL {
        let bundle = folder.appendingPathComponent("plain.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(Self.reads.utf8).write(to: bundle.appendingPathComponent("reads.fastq"))
        return bundle
    }

    private func chunkedBundle(compressed: Bool = false) throws -> URL {
        let bundle = folder.appendingPathComponent("chunked.lungfishfastq", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for index in 0..<3 {
            let data = Data("@c\(index)\nACGT\n+\nIIII\n".utf8)
            try data.write(to: chunks.appendingPathComponent("sample_\(index).fastq"))
            entries.append(.init(
                filename: "chunks/sample_\(index).fastq", originalPath: "/run/sample_\(index).fastq",
                sizeBytes: Int64(data.count), isSymlink: false
            ))
        }
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        return bundle
    }

    private func derivedBundle() throws -> URL {
        let bundle = folder.appendingPathComponent("derived.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(Self.reads.utf8).write(to: bundle.appendingPathComponent("full.fastq"))
        let operation = FASTQDerivativeOperation(kind: .subsampleCount)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "derived",
                parentBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootBundleRelativePath: "@/Imports/root.lungfishfastq",
                rootFASTQFilename: "root.fastq",
                payload: .full(fastqFilename: "full.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: 2, baseCount: 8),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return bundle
    }

    private func command(_ arguments: [String]) throws -> FastqExportReadsSubcommand {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        return try XCTUnwrap(parsed as? FastqExportReadsSubcommand)
    }

    @discardableResult
    private func export(_ bundle: URL, to output: URL, extra: [String] = []) async throws -> ViewerExportLeafOutcome {
        try await command(["fastq", "export", "reads", bundle.path, "--output", output.path] + extra)
            .export(events: CLIEventEmitter(enabled: false, emit: { _ in }))
    }

    private static func envelope(of outputURL: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)))
    }

    private func assertNothingWritten(_ output: URL, _ message: String) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path), message)
    }

    /// A plain bundle is copied. The record names the CLI, the leaf's own argv, the file it opened and its digest.
    func testAPlainBundleIsCopiedAndRecordedOnTheCLIIdentity() async throws {
        let bundle = try plainBundle()
        let output = folder.appendingPathComponent("plain.fastq")
        try await export(bundle, to: output)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), Self.reads)

        let record = try Self.envelope(of: output)
        let invocation = FASTQReadsExport.invocation(bundleURL: bundle, outputURL: output, isDerived: false, force: false, emitsEvents: false)
        XCTAssertEqual(record.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(record.tool.kind, "cli")
        XCTAssertEqual(record.workflowName, FASTQReadsExport.workflowName)
        XCTAssertEqual(record.argv, invocation.canonicalArgv())
        XCTAssertEqual(record.durableReplayArgv, record.argv)
        XCTAssertEqual(record.options.explicit.keys.sorted(), ["outputPath"])
        XCTAssertEqual(record.options.resolvedDefaults["isDerived"], .boolean(false))
        XCTAssertEqual(record.options.resolvedDefaults["inputChunkCount"], .integer(1))
        XCTAssertEqual(record.options.resolvedDefaults["outputGzipCompressed"], .boolean(false))
        let inputs = record.files.filter { $0.role == .input }
        XCTAssertEqual(inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["reads.fastq"])
        XCTAssertNotNil(inputs.first?.checksumSHA256)
    }

    /// Several chunks are joined in manifest order, and the record names every chunk and the manifest.
    func testSeveralChunksAreJoinedInManifestOrder() async throws {
        let bundle = try chunkedBundle()
        let output = folder.appendingPathComponent("chunked.fastq")
        try await export(bundle, to: output)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "@c0\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n@c2\nACGT\n+\nIIII\n"
        )
        let record = try Self.envelope(of: output)
        XCTAssertEqual(record.options.resolvedDefaults["inputChunkCount"], .integer(3))
        let names = record.files.filter { $0.role == .input }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
        XCTAssertEqual(names, ["sample_0.fastq", "sample_1.fastq", "sample_2.fastq", "source-files.json"])
    }

    /// Plain chunks written to a `.fastq.gz` go through the gzip step and read back as the chunks in order.
    func testAGzipOutputOfPlainChunksReadsBackAsTheChunks() async throws {
        let bundle = try chunkedBundle()
        let output = folder.appendingPathComponent("chunked.fastq.gz")
        try await export(bundle, to: output)
        var lines: [String] = []
        for try await line in URL.multiFileLinesAutoDecompressing([output]) {
            lines.append(line)
        }
        XCTAssertEqual(lines.joined(separator: "\n") + "\n", "@c0\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n@c2\nACGT\n+\nIIII\n")
        XCTAssertEqual(try Self.envelope(of: output).options.resolvedDefaults["outputGzipCompressed"], .boolean(true))
    }

    /// A derived bundle needs `--materialize-derived`. With it the leaf writes the reads the bundle stands for.
    func testADerivedBundleNeedsTheFlagAndIsMaterializedWithIt() async throws {
        let bundle = try derivedBundle()
        let output = folder.appendingPathComponent("derived.fastq")
        do {
            try await export(bundle, to: output)
            XCTFail("a derived bundle without --materialize-derived must be refused")
        } catch {
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        assertNothingWritten(output, "a refusal writes nothing")

        try await export(bundle, to: output, extra: ["--materialize-derived"])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), Self.reads)
        let record = try Self.envelope(of: output)
        XCTAssertEqual(record.options.explicit["materializeDerived"], .boolean(true))
        XCTAssertEqual(record.options.resolvedDefaults["isDerived"], .boolean(true))
        XCTAssertEqual(record.options.resolvedDefaults["inputChunkCount"], .integer(0))
        XCTAssertTrue(record.argv.contains("--materialize-derived"))
    }

    /// An existing output is refused without `--force` and replaced with it, with its record.
    func testAnExistingOutputIsRefusedWithoutForceAndReplacedWithIt() async throws {
        let bundle = try plainBundle()
        let output = folder.appendingPathComponent("again.fastq")
        try await export(bundle, to: output)
        try Data("@old\nA\n+\nI\n".utf8).write(to: output)
        do {
            try await export(bundle, to: output)
            XCTFail("an existing output must be refused without --force")
        } catch {
            XCTAssertTrue(error is ViewerExportRefusal, "\(error)")
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "@old\nA\n+\nI\n")

        try await export(bundle, to: output, extra: ["--force"])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), Self.reads)
        let record = try Self.envelope(of: output)
        XCTAssertEqual(record.options.explicit["force"], .boolean(true))
        XCTAssertEqual(record.output?.fileSize, UInt64(Self.reads.utf8.count), "the record describes the replaced file")
    }

    /// Each refusal exits before anything is written.
    func testRefusalsLeaveNoOutputAndNoRecord() async throws {
        let bundle = try plainBundle()
        let empty = folder.appendingPathComponent("empty.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let refusals: [(name: String, bundle: URL, output: URL)] = [
            ("a missing bundle", folder.appendingPathComponent("missing.lungfishfastq"), folder.appendingPathComponent("a.fastq")),
            ("a bundle with no FASTQ file", empty, folder.appendingPathComponent("b.fastq")),
            ("a missing output folder", bundle, folder.appendingPathComponent("no-such-folder/c.fastq")),
            ("an output that is an input", bundle, bundle.appendingPathComponent("reads.fastq")),
        ]
        for refusal in refusals {
            do {
                try await export(refusal.bundle, to: refusal.output)
                XCTFail("\(refusal.name) must be refused")
            } catch {
                XCTAssertTrue(error is ViewerExportRefusal, "\(refusal.name): \(error)")
            }
            if refusal.name != "an output that is an input" {
                assertNothingWritten(refusal.output, refusal.name)
            }
        }
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("reads.fastq"), encoding: .utf8), Self.reads)
    }

    /// A failed export over an existing file keeps the old file and its record, and leaves no staged file behind. This
    /// is the rollback the in-app writer's backup gave, which is now the leaf's transaction.
    func testAFailedExportOverAnExistingFileKeepsTheOldFileAndItsRecord() async throws {
        let bundle = try chunkedBundle()
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("chunks/sample_1.fastq"))
        let output = folder.appendingPathComponent("again.fastq")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        try "old payload\n".write(to: output, atomically: true, encoding: .utf8)
        try "old provenance\n".write(to: sidecar, atomically: true, encoding: .utf8)
        do {
            try await export(bundle, to: output, extra: ["--force"])
            XCTFail("an export whose manifest chunk is missing must fail")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "old payload\n")
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "old provenance\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix(".again") }, "no staged file is left: \(entries)")
    }

    /// The arguments the sidebar's begin helper builds parse through the root into the leaf, whose canonical argv is
    /// the executable name and the same array.
    func testFastqExportReadsParsesTheGUIArguments() throws {
        let bundle = try derivedBundle()
        let invocation = FASTQReadsExport.invocation(
            bundleURL: bundle, outputURL: folder.appendingPathComponent("gui out.fastq.gz"), isDerived: true, force: true
        )
        let arguments = invocation.arguments()
        let leaf = try command(arguments)
        XCTAssertEqual(leaf.invocation(), invocation)
        XCTAssertEqual(leaf.invocation().canonicalArgv(), [CLICommandIdentity.executableName] + arguments)
        XCTAssertEqual(Array(arguments.prefix(3)), FASTQReadsExport.commandPath)
        XCTAssertTrue(leaf.materializeDerived)
        XCTAssertEqual(FastqExportReadsSubcommand.configuration.commandName, FASTQReadsExport.commandPath.last)
        XCTAssertThrowsError(try command(["fastq", "export", "reads", bundle.path, "--sample", "S1", "--output", "/tmp/x.fastq"]))
    }
}
