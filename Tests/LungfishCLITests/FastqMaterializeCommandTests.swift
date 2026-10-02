// FastqMaterializeCommandTests.swift - Tests for FASTQ materialization CLI behavior
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class FastqMaterializeCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-materialize-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testMaterializeCompressWritesGzipPayloadAndConsistentProvenance() async throws {
        let bundleURL = try makePhysicalFASTQBundle()
        let outputURL = tempDir.appendingPathComponent("materialized.fastq.gz")
        let command = try FastqMaterializeSubcommand.parse([
            bundleURL.path,
            "--output", outputURL.path,
            "--compress",
        ])

        try await command.run()

        let outputData = try Data(contentsOf: outputURL)
        XCTAssertEqual(Array(outputData.prefix(2)), [0x1f, 0x8b])

        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["compress"], .boolean(true))
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == outputURL.path && $0.checksumSHA256 != nil && $0.fileSize == UInt64(outputData.count)
        })
    }

    func testMaterializeFastaBackedDerivedBundleRecordsFastaFormatAndBundleInputs() async throws {
        let bundleURL = try makeFullFASTADerivedBundle()
        let outputURL = tempDir.appendingPathComponent("materialized.fasta")
        let command = try FastqMaterializeSubcommand.parse([
            bundleURL.path,
            "--output", outputURL.path,
        ])

        try await command.run()

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), ">read1\nACGT\n")
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let manifestURL = FASTQBundle.derivedManifestURL(in: bundleURL)
        let payloadURL = bundleURL.appendingPathComponent("reads.fasta")

        XCTAssertEqual(envelope.options.resolvedDefaults["outputFormat"], .string("fasta"))
        XCTAssertTrue(envelope.files.contains {
            $0.path == bundleURL.path && $0.role == .input && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == manifestURL.path && $0.format == .json && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.files.contains {
            $0.path == payloadURL.path && $0.format == .fasta && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == outputURL.path && $0.format == .fasta && $0.checksumSHA256 != nil
        })
        XCTAssertTrue(envelope.steps.first?.outputs.contains {
            $0.path == outputURL.path && $0.format == .fasta && $0.checksumSHA256 != nil
        } == true)
    }

    // MARK: - Bundle shapes (R3, lane 1n)

    func testEachBundleShapeMaterializesEveryReadItHolds() async throws {
        let shapes = try BundleShapeFixtures(
            in: tempDir.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        )
        // fullPaired and fullMixed bundles interleave their mates with the
        // managed reformat.sh, which this lane does not change.
        let cases: [(shape: String, bundle: URL, output: String, reads: [String])] = [
            ("root single", shapes.single, "single.fastq", ["s1", "s2", "s3"]),
            ("root multi-file", shapes.multiFile, "multi.fastq", ["m1", "m2", "m3", "m4", "m5"]),
            ("virtual orientMap", shapes.oriented, "oriented.fastq", ["s1", "s3"]),
            ("derived fullFASTA", shapes.fasta, "converted.fasta", ["f1", "f2"]),
            ("derived full", shapes.full, "full.fastq", ["g1", "g2"]),
        ]
        for testCase in cases {
            let outputURL = tempDir.appendingPathComponent(testCase.output)
            try await FastqMaterializeSubcommand.parse([testCase.bundle.path, "--output", outputURL.path]).run()
            XCTAssertEqual(try BundleShapeFixtures.readNames(in: outputURL), testCase.reads, testCase.shape)
        }
    }

    func testAMultiFileBundleRecordsEveryChunkAndLeavesNoJoinedCopyBehind() async throws {
        let shapes = try BundleShapeFixtures(
            in: tempDir.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        )
        let outputURL = tempDir.appendingPathComponent("multi.fastq")
        let workDirectory = tempDir.appendingPathComponent("work", isDirectory: true)
        try await FastqMaterializeSubcommand.parse([
            shapes.multiFile.path, "--output", outputURL.path, "--temp-dir", workDirectory.path,
        ]).run()

        XCTAssertEqual(try BundleShapeFixtures.readNames(in: outputURL), ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDirectory.path), [])
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        let chunks = shapes.multiFileChunks.map(\.standardizedFileURL)
        for chunk in chunks {
            XCTAssertTrue(
                envelope.files.contains { $0.path == chunk.path && $0.role == .input && $0.checksumSHA256 != nil },
                "\(chunk.lastPathComponent) is a recorded input"
            )
        }
        XCTAssertEqual(envelope.options.explicit["inputPayloads"], .array(chunks.map { .file($0) }))
        XCTAssertNil(envelope.options.explicit["inputPayload"])
    }

    func testGzipChunksJoinIntoOneReadableGzipFile() async throws {
        let bundle = tempDir.appendingPathComponent("ont.\(FASTQBundle.directoryExtension)", isDirectory: true)
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for (index, names) in [["a1", "a2"], ["b1"]].enumerated() {
            let plain = tempDir.appendingPathComponent("chunk-\(index).fastq")
            try BundleShapeFixtures.fastq(names).write(to: plain, atomically: true, encoding: .utf8)
            let gzipped = chunks.appendingPathComponent("chunk_\(index).fastq.gz")
            try Self.gzip(plain, to: gzipped)
            entries.append(.init(filename: "chunks/chunk_\(index).fastq.gz", originalPath: plain.path, sizeBytes: 1, isSymlink: false))
        }
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        let outputURL = tempDir.appendingPathComponent("ont.fastq.gz")

        try await FastqMaterializeSubcommand.parse([bundle.path, "--output", outputURL.path]).run()

        let decompressed = tempDir.appendingPathComponent("ont-decompressed.fastq")
        try Self.gunzip(outputURL, to: decompressed)
        XCTAssertEqual(try BundleShapeFixtures.readNames(in: decompressed), ["a1", "a2", "b1"])
    }

    func testABundleMixingGzipAndPlainChunksIsRefused() async throws {
        let bundle = tempDir.appendingPathComponent("mixed-compression.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plain = bundle.appendingPathComponent("chunk_0.fastq")
        try BundleShapeFixtures.fastq(["a1"]).write(to: plain, atomically: true, encoding: .utf8)
        try Self.gzip(plain, to: bundle.appendingPathComponent("chunk_1.fastq.gz"))
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunk_0.fastq", originalPath: "/orig/0", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunk_1.fastq.gz", originalPath: "/orig/1", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)
        let outputURL = tempDir.appendingPathComponent("mixed.fastq")

        await XCTAssertThrowsErrorAsync(
            try await FastqMaterializeSubcommand.parse([bundle.path, "--output", outputURL.path]).run()
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    private static func gzip(_ source: URL, to destination: URL) throws {
        try run("/usr/bin/gzip", ["-c", source.path], stdout: destination)
    }

    private static func gunzip(_ source: URL, to destination: URL) throws {
        try run("/usr/bin/gzip", ["-dc", source.path], stdout: destination)
    }

    private static func run(_ executable: String, _ arguments: [String], stdout destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
    }

    private func makePhysicalFASTQBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("reads.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let payloadURL = bundleURL.appendingPathComponent("reads.fastq")
        try Data("@read1\nACGT\n+\nIIII\n".utf8).write(to: payloadURL)
        return bundleURL
    }

    private func makeFullFASTADerivedBundle() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("reads-fasta.\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let payloadURL = bundleURL.appendingPathComponent("reads.fasta")
        try Data(">read1\nACGT\n".utf8).write(to: payloadURL)
        let manifest = FASTQDerivedBundleManifest(
            name: "reads-fasta",
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: "reads.fasta",
            payload: .fullFASTA(fastaFilename: "reads.fasta"),
            lineage: [],
            operation: FASTQDerivativeOperation(kind: .reverseComplement),
            cachedStatistics: .placeholder(readCount: 1, baseCount: 4),
            pairingMode: nil,
            sequenceFormat: .fasta
        )
        try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
        return bundleURL
    }
}
