// FASTQDerivativeMultiFileRootTests.swift - A dashboard derivative of a multi-file bundle covers every file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ dataset viewport runs its operations in process through
// FASTQDerivativeService.createDerivative. For a bundle that holds several
// files (an ONT import, listed in source-files.json) it used to read chunk 0
// alone and record the chunk's bare name as the root file, so the derivative
// covered a fraction of the reads the dashboard counted and could not be
// materialized at all. It now reads every file through FASTQCLIMaterializer
// and records the member path, so the derivative covers every file,
// materializes through the app and through `lungfish-cli fastq materialize`
// to exactly the reads its read-ID list and statistics describe, and the
// command the operation records gives the same reads (R3, lane 1x).
//
// The reverse complement runs in pure Swift. The length filter runs seqkit
// and the fixed trim runs fastp, so those skip when the tools are missing.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class FASTQDerivativeMultiFileRootTests: XCTestCase {
    private var root: URL!
    private var multiFile: URL!
    private var chunks: [URL] = []

    /// Reads of two lengths across two chunks, so a length filter keeps
    /// reads from both and a trim changes every read.
    private static let reads: [(chunk: Int, id: String, sequence: String)] = [
        (0, "m1", "AAAACCCCGGTT"),
        (0, "m2", "TTTTGG"),
        (1, "m3", "ACGTACGTACGT"),
        (1, "m4", "GGGGCC"),
        (1, "m5", "TTTTAAAACCGG"),
    ]

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-derivative-multi-file-root")
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        multiFile = imports.appendingPathComponent("multi.lungfishfastq", isDirectory: true)
        let chunksDirectory = multiFile.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        chunks = [chunksDirectory.appendingPathComponent("run_0.fastq"), chunksDirectory.appendingPathComponent("run_1.fastq")]
        for (index, chunk) in chunks.enumerated() {
            try FASTQOperationTestHelper.writeFASTQ(
                records: Self.reads.filter { $0.chunk == index }.map { ($0.id, $0.sequence) },
                to: chunk
            )
        }
        try FASTQOperationTestHelper.writeFASTQ(records: [("m1", "AAAACCCCGGTT")], to: multiFile.appendingPathComponent("preview.fastq"))
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: multiFile)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func records(_ url: URL) async throws -> [(id: String, sequence: String)] {
        try await FASTQOperationTestHelper.loadFASTQRecords(from: url).map { ($0.identifier, $0.sequence) }
    }

    private func requireTool(_ tool: NativeTool) async throws {
        guard await NativeToolRunner.shared.isToolAvailable(tool) else {
            try ToolAvailability.skipOrFail("managed \(tool.rawValue) is not installed")
        }
    }

    /// The reads the derivative holds through the app's materialization,
    /// through `lungfish-cli fastq materialize`, and through the command the
    /// dashboard records for the request, which must all agree.
    private func assertEveryPathAgrees(
        derivative: URL,
        request: FASTQDerivativeRequest,
        expected: [(id: String, sequence: String)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: derivative), file: file, line: line)
        XCTAssertEqual(manifest.cachedStatistics.readCount, expected.count, "the cached statistics count the reads the derivative holds", file: file, line: line)

        let appMaterialized = root.appendingPathComponent("app-\(UUID().uuidString).fastq")
        try await FASTQDerivativeService.shared.exportMaterializedFASTQ(fromDerivedBundle: derivative, to: appMaterialized)
        let appRecords = try await records(appMaterialized)
        XCTAssertEqual(appRecords.map(\.id), expected.map(\.id), "app materialization", file: file, line: line)
        XCTAssertEqual(appRecords.map(\.sequence), expected.map(\.sequence), "app materialization", file: file, line: line)

        let cliMaterialized = root.appendingPathComponent("cli-\(UUID().uuidString).fastq")
        try await FastqMaterializeSubcommand.parse([derivative.path, "--output", cliMaterialized.path]).run()
        XCTAssertEqual(try Data(contentsOf: cliMaterialized), try Data(contentsOf: appMaterialized), "lungfish-cli fastq materialize", file: file, line: line)

        let replayOutput = root.appendingPathComponent("replay-\(UUID().uuidString).fastq")
        let recorded = try XCTUnwrap(
            request.cliCommand(inputPath: multiFile.path, outputPath: replayOutput.path),
            "the dashboard records a command for this request",
            file: file,
            line: line
        )
        let command = try RecordedCLICommand.parse(recorded)
        guard var runnable = command as? AsyncParsableCommand else {
            return XCTFail("\(type(of: command))", file: file, line: line)
        }
        try await runnable.run()
        let replayRecords = try await records(replayOutput)
        XCTAssertEqual(replayRecords.map(\.id), expected.map(\.id), "the recorded command", file: file, line: line)
        XCTAssertEqual(replayRecords.map(\.sequence), expected.map(\.sequence), "the recorded command", file: file, line: line)
    }

    func testALengthFilterSubsetCoversReadsFromEveryFile() async throws {
        try await requireTool(.seqkit)
        let request = FASTQDerivativeRequest.lengthFilter(min: 8, max: nil)
        let derivative = try await FASTQDerivativeService.shared.createDerivative(from: multiFile, request: request)

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: derivative))
        XCTAssertEqual(manifest.rootFASTQFilename, "chunks/run_0.fastq", "the member path, not the bare name")
        guard case .subset(let readIDListFilename) = manifest.payload else { return XCTFail("\(manifest.payload)") }
        let readIDs = try String(contentsOf: derivative.appendingPathComponent(readIDListFilename), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(readIDs, ["m1", "m3", "m5"], "reads from both chunks")

        try await assertEveryPathAgrees(
            derivative: derivative,
            request: request,
            expected: Self.reads.filter { $0.sequence.count >= 8 }.map { ($0.id, $0.sequence) }
        )
    }

    func testAFixedTrimCoversReadsFromEveryFile() async throws {
        try await requireTool(.fastp)
        let request = FASTQDerivativeRequest.fixedTrim(from5Prime: 2, from3Prime: 0)
        let derivative = try await FASTQDerivativeService.shared.createDerivative(from: multiFile, request: request)

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: derivative))
        XCTAssertEqual(manifest.rootFASTQFilename, "chunks/run_0.fastq")
        guard case .trim = manifest.payload else { return XCTFail("\(manifest.payload)") }
        let trimRecords = try FASTQTrimPositionFile.loadRecords(from: derivative.appendingPathComponent(FASTQBundle.trimPositionFilename))
        XCTAssertEqual(trimRecords.map(\.readID), ["m1#0", "m2#0", "m3#0", "m4#0", "m5#0"], "a trim row for every read of both chunks")

        try await assertEveryPathAgrees(
            derivative: derivative,
            request: request,
            expected: Self.reads.map { ($0.id, String($0.sequence.dropFirst(2))) }
        )
    }

    func testAReverseComplementFullPayloadCoversReadsFromEveryFile() async throws {
        let request = FASTQDerivativeRequest.reverseComplement
        let derivative = try await FASTQDerivativeService.shared.createDerivative(from: multiFile, request: request)

        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: derivative))
        guard case .full = manifest.payload else { return XCTFail("\(manifest.payload)") }

        try await assertEveryPathAgrees(
            derivative: derivative,
            request: request,
            expected: Self.reads.map { ($0.id, FASTQOperationTestHelper.reverseComplement($0.sequence)) }
        )
    }

    /// A derivative of the derivative keeps the member path, so a chain over
    /// a multi-file root materializes at every link.
    func testADerivativeOfADerivativeKeepsTheMemberPath() async throws {
        try await requireTool(.seqkit)
        let first = try await FASTQDerivativeService.shared.createDerivative(from: multiFile, request: .lengthFilter(min: 8, max: nil))
        let second = try await FASTQDerivativeService.shared.createDerivative(from: first, request: .lengthFilter(min: 1, max: 12))
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: second))
        XCTAssertEqual(manifest.rootFASTQFilename, "chunks/run_0.fastq")
        XCTAssertEqual(manifest.cachedStatistics.readCount, 3)
        let materialized = root.appendingPathComponent("second.fastq")
        try await FASTQDerivativeService.shared.exportMaterializedFASTQ(fromDerivedBundle: second, to: materialized)
        let names = try await records(materialized).map(\.id)
        XCTAssertEqual(names, ["m1", "m3", "m5"])
    }
}
