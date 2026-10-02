// ResolvedSequenceInputsTests.swift - The window's input resolution keeps every file and its lineage
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

final class ResolvedSequenceInputsTests: XCTestCase {

    private var root: URL!
    private var imports: URL!
    private var materializationDirectory: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "resolved-sequence-inputs")
        imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        materializationDirectory = root.appendingPathComponent("analysis/.lungfish-map-inputs", isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testRootBundleResolvesToItsFASTQWithoutMaterializing() async throws {
        let bundle = try makeBundle("single")
        let fastq = bundle.appendingPathComponent("single.fastq")
        try Self.fastq(["s1", "s2"]).write(to: fastq, atomically: true, encoding: .utf8)

        let resolved = try await resolve([bundle])

        XCTAssertEqual(resolved.executionInputURLs, [fastq.standardizedFileURL])
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL])
        XCTAssertFalse(resolved.didMaterialize)
        XCTAssertNil(resolved.materializationStartedAt)
        XCTAssertNil(resolved.materializationEndedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materializationDirectory.path))
    }

    func testMultiFileBundleResolvesToEveryChunkAlignedToTheBundle() async throws {
        let bundle = try makeBundle("multi")
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        let chunk0 = chunks.appendingPathComponent("run_0.fastq")
        let chunk1 = chunks.appendingPathComponent("run_1.fastq")
        try Self.fastq(["m1", "m2"]).write(to: chunk0, atomically: true, encoding: .utf8)
        try Self.fastq(["m3"]).write(to: chunk1, atomically: true, encoding: .utf8)
        try Self.fastq(["m1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/run_0.fastq", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/run_1.fastq", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)

        let resolved = try await resolve([bundle])

        XCTAssertEqual(resolved.executionInputURLs, [chunk0.standardizedFileURL, chunk1.standardizedFileURL])
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL, bundle.standardizedFileURL])
        XCTAssertFalse(resolved.didMaterialize)
    }

    func testVirtualBundleIsMaterializedIntoTheDirectoryWithTimestamps() async throws {
        let fixture = try DerivedFASTQBundleFixture.make(in: root)

        let before = Date()
        let resolved = try await resolve([fixture.derivedBundleURL])
        let after = Date()

        let executionURL = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(resolved.executionInputURLs.count, 1)
        XCTAssertEqual(
            executionURL.deletingLastPathComponent().standardizedFileURL,
            materializationDirectory.standardizedFileURL
        )
        XCTAssertEqual(resolved.originalInputURLs, [fixture.derivedBundleURL.standardizedFileURL])
        XCTAssertEqual(resolved.materializedExecutionURLs, [executionURL])
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: executionURL), ["read1", "read3"])
        let startedAt = try XCTUnwrap(resolved.materializationStartedAt)
        let endedAt = try XCTUnwrap(resolved.materializationEndedAt)
        XCTAssertGreaterThanOrEqual(startedAt, before)
        XCTAssertLessThanOrEqual(startedAt, endedAt)
        XCTAssertLessThanOrEqual(endedAt, after)
    }

    func testFullPairedBundleResolvesToBothMatesAlignedToTheBundle() async throws {
        let bundle = try makeBundle("paired")
        let r1 = bundle.appendingPathComponent("sample_R1.fastq")
        let r2 = bundle.appendingPathComponent("sample_R2.fastq")
        try Self.fastq(["p1/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(["p1/2"]).write(to: r2, atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .interleaveReformat)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "paired",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "sample_R1.fastq",
                payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .pairedEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )

        let resolved = try await resolve([bundle])

        XCTAssertEqual(resolved.executionInputURLs, [r1.standardizedFileURL, r2.standardizedFileURL])
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL, bundle.standardizedFileURL])
        XCTAssertFalse(resolved.didMaterialize)
    }

    func testFullFASTABundleResolvesToItsFASTAInPlace() async throws {
        let bundle = try makeBundle("converted")
        let fasta = bundle.appendingPathComponent("converted.fasta")
        try ">f1\nACGTACGTAC\n>f2\nACGTACGTAC\n".write(to: fasta, atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .translate)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "converted",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "converted.fasta",
                payload: .fullFASTA(fastaFilename: "converted.fasta"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: .singleEnd,
                sequenceFormat: .fasta
            ),
            in: bundle
        )

        let resolved = try await resolve([bundle])

        XCTAssertEqual(resolved.executionInputURLs, [fasta.standardizedFileURL])
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL])
        XCTAssertFalse(resolved.didMaterialize)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: materializationDirectory.path),
            "a fullFASTA bundle is read in place, never copied"
        )
    }

    func testLooseFASTQResolvesToItself() async throws {
        let fastq = root.appendingPathComponent("loose.fastq")
        try Self.fastq(["l1"]).write(to: fastq, atomically: true, encoding: .utf8)

        let resolved = try await resolve([fastq])

        XCTAssertEqual(resolved.executionInputURLs, [fastq.standardizedFileURL])
        XCTAssertEqual(resolved.originalInputURLs, [fastq.standardizedFileURL])
        XCTAssertFalse(resolved.didMaterialize)
    }

    func testFailureRemovesWhatWasMaterialized() async throws {
        let fixture = try DerivedFASTQBundleFixture.make(in: root)
        let missingBundle = imports.appendingPathComponent("missing.lungfishfastq", isDirectory: true)

        await XCTAssertThrowsErrorAsync(
            try await resolve([fixture.derivedBundleURL, missingBundle]),
            "a bundle that does not exist must fail the resolution"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: materializationDirectory.path),
            "the materialization directory this call created must be removed"
        )
    }

    func testFailureKeepsWhatWasAlreadyInTheDirectory() async throws {
        let fixture = try DerivedFASTQBundleFixture.make(in: root)
        let missingBundle = imports.appendingPathComponent("missing.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: materializationDirectory, withIntermediateDirectories: true)
        let keep = materializationDirectory.appendingPathComponent("keep.txt")
        try "keep".write(to: keep, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await resolve([fixture.derivedBundleURL, missingBundle]))

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: materializationDirectory.path),
            ["keep.txt"]
        )
    }

    func testRequestLineageFollowsTheResolution() async throws {
        let fixture = try DerivedFASTQBundleFixture.make(in: root)
        let resolved = try await resolve([fixture.derivedBundleURL])

        let request = Self.request(inputFASTQURLs: [fixture.derivedBundleURL])
            .withInputFASTQURLs(resolved.executionInputURLs, pairedEnd: false)
            .withInputLineage(resolved)

        XCTAssertEqual(request.inputFASTQURLs, resolved.executionInputURLs)
        XCTAssertEqual(request.originalInputFASTQURLs, [fixture.derivedBundleURL.standardizedFileURL])
        XCTAssertEqual(request.inputMaterializationStartedAt, resolved.materializationStartedAt)
        XCTAssertEqual(request.inputMaterializationEndedAt, resolved.materializationEndedAt)
    }

    func testPipelineRecordsTheMaterializationStepFromTheLineage() async throws {
        let fixture = try DerivedFASTQBundleFixture.make(in: root)
        let resolved = try await resolve([fixture.derivedBundleURL])
        let request = Self.request(inputFASTQURLs: [fixture.derivedBundleURL])
            .withInputFASTQURLs(resolved.executionInputURLs, pairedEnd: false)
            .withInputLineage(resolved)

        let steps = try ManagedMappingPipeline().mappingInputMaterializationStepsForTesting(request: request)

        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(step.toolName, CLISequenceInputMaterialization.materializationToolName)
        XCTAssertEqual(
            step.command,
            CLISequenceInputMaterialization.materializationCommand(
                originalURL: fixture.derivedBundleURL,
                executionURL: resolved.executionInputURLs[0]
            )
        )
        XCTAssertTrue(step.inputs.contains { $0.path == fixture.derivedBundleURL.standardizedFileURL.path })
        XCTAssertTrue(step.outputs.contains { $0.path == resolved.executionInputURLs[0].path })
    }

    // MARK: - Helpers

    private func resolve(_ inputURLs: [URL]) async throws -> ResolvedSequenceInputs {
        try await ResolvedSequenceInputs.resolve(
            inputURLs: inputURLs,
            materializationDirectory: materializationDirectory,
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
    }

    private func makeBundle(_ name: String) throws -> URL {
        let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    private static func request(inputFASTQURLs: [URL]) -> MappingRunRequest {
        MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            inputFASTQURLs: inputFASTQURLs,
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/reference.fa"),
            outputDirectory: URL(fileURLWithPath: "/tmp/analysis"),
            sampleName: "sample",
            threads: 1
        )
    }
}
