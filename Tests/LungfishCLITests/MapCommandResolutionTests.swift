// MapCommandResolutionTests.swift - lungfish-cli map resolves a bundle the way the Map Reads window does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// A bundle argument to `lungfish-cli map` maps the same reads, paired the
/// same way, as the Map Reads window maps the bundle, so the command the
/// Operations panel records reproduces the window's run.
final class MapCommandResolutionTests: XCTestCase {

    private var root: URL!
    private var imports: URL!
    private var inputsDirectory: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "map-command-resolution")
        imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        inputsDirectory = root.appendingPathComponent("analysis/.lungfish-map-inputs", isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAFullPairedBundleResolvesToItsMatesAndMapsAsPairs() async throws {
        let bundle = try makeBundle("paired")
        let r1 = bundle.appendingPathComponent("sample_R1.fastq")
        let r2 = bundle.appendingPathComponent("sample_R2.fastq")
        try Self.fastq(["p1/1", "p2/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(["p1/2", "p2/2"]).write(to: r2, atomically: true, encoding: .utf8)
        try Self.saveDerivedManifest(
            in: bundle,
            name: "paired",
            rootFile: "sample_R1.fastq",
            payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
            kind: .interleaveReformat,
            pairing: .pairedEnd
        )

        let resolved = try await resolve([bundle])

        XCTAssertEqual(resolved.request.inputFASTQURLs, [r1.standardizedFileURL, r2.standardizedFileURL])
        XCTAssertTrue(resolved.request.pairedEnd)
        XCTAssertNil(resolved.readSetPlan, "a sample of only pairs keeps its command")
        XCTAssertEqual(resolved.layoutResolution.layout, .pairedFiles)
        XCTAssertEqual(resolved.layoutResolution.source, .pairedFiles)
    }

    /// `--read-layout` describes one file, so a bundle whose reads are R1
    /// and R2 files, with or without single reads, refuses it.
    func testReadLayoutIsRefusedForABundleOfMateFiles() async throws {
        let fixtures = try ReadSetFixtures(in: root.appendingPathComponent("read-sets", isDirectory: true))
        for bundle in [fixtures.pairedDerivative, fixtures.mergeDerivative, fixtures.repairDerivative] {
            await XCTAssertThrowsErrorAsync(try await resolve([bundle], explicitLayout: .singleEnd)) { error in
                XCTAssertEqual(
                    error as? MappingInputResolverError,
                    .layoutForPairedBundle(name: bundle.lastPathComponent),
                    bundle.lastPathComponent
                )
            }
        }
        let single = try await resolve([fixtures.singleRoot], explicitLayout: .singleEnd)
        XCTAssertEqual(single.layoutResolution.source, .explicit)
    }

    func testAMultiFileBundleResolvesToOneConcatenatedFileMappedAsSingleReads() async throws {
        let bundle = try makeBundle("multi")
        let chunks = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Self.fastq(["m1", "m2"]).write(to: chunks.appendingPathComponent("run_0.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq(["m3"]).write(to: chunks.appendingPathComponent("run_1.fastq"), atomically: true, encoding: .utf8)
        try Self.fastq(["m1"]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/run_0.fastq", originalPath: "/orig/0", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/run_1.fastq", originalPath: "/orig/1", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)

        let resolved = try await resolve([bundle])

        let executionURL = try XCTUnwrap(resolved.request.inputFASTQURLs.first)
        XCTAssertEqual(resolved.request.inputFASTQURLs.count, 1)
        XCTAssertEqual(executionURL.deletingLastPathComponent().standardizedFileURL, inputsDirectory.standardizedFileURL)
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: executionURL), ["m1", "m2", "m3"])
        XCTAssertFalse(resolved.request.pairedEnd)
        XCTAssertEqual(resolved.layoutResolution.layout, .singleEnd)
        XCTAssertEqual(resolved.layoutResolution.source, .pooledFiles)
        let explicit = try await resolve([bundle], explicitLayout: .strictlyInterleaved)
        XCTAssertEqual(explicit.layoutResolution.layout, .strictlyInterleaved, "an explicit --read-layout still wins")
    }

    func testPairedFlagStillBindsTwoLooseFiles() async throws {
        let r1 = root.appendingPathComponent("reads_R1.fastq")
        let r2 = root.appendingPathComponent("reads_R2.fastq")
        try Self.fastq(["p1/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(["p1/2"]).write(to: r2, atomically: true, encoding: .utf8)

        let unpaired = try await resolve([r1, r2])
        let paired = try await resolve([r1, r2], pairedEnd: true)

        XCTAssertEqual(unpaired.request.inputFASTQURLs, [r1.standardizedFileURL, r2.standardizedFileURL])
        XCTAssertFalse(unpaired.request.pairedEnd, "two separate inputs are bound by --paired, not by their names")
        XCTAssertTrue(paired.request.pairedEnd)
        XCTAssertEqual(paired.layoutResolution.layout, .pairedFiles)
    }

    func testADemuxGroupBundleIsRefusedBeforeAnythingIsWritten() async throws {
        let bundle = try makeBundle("group")
        try Self.saveDerivedManifest(
            in: bundle,
            name: "group",
            rootFile: "none.fastq",
            payload: .demuxGroup(barcodeCount: 2),
            kind: .demultiplex,
            pairing: .singleEnd
        )

        await XCTAssertThrowsErrorAsync(try await resolve([bundle])) { error in
            guard case CLISequenceInputMaterializationError.unsupportedSequenceInput = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: inputsDirectory.path))
    }

    func testAnUnreadableLooseInputIsRefused() async throws {
        let notReads = root.appendingPathComponent("notes.txt")
        try "hello".write(to: notReads, atomically: true, encoding: .utf8)

        await XCTAssertThrowsErrorAsync(try await resolve([notReads])) { error in
            guard case CLISequenceInputMaterializationError.unreadableSequenceInput = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// Resolves through the call `lungfish-cli map` and the Map Reads window make.
    private func resolve(
        _ inputURLs: [URL],
        pairedEnd: Bool = false,
        explicitLayout: FASTQInputLayout? = nil
    ) async throws -> MappingResolvedInputs {
        try await MappingInputResolver.resolve(
            request: MappingRunRequest(
                tool: .minimap2,
                modeID: MappingMode.defaultShortRead.id,
                inputFASTQURLs: inputURLs,
                referenceFASTAURL: root.appendingPathComponent("reference.fa"),
                outputDirectory: inputsDirectory.deletingLastPathComponent(),
                sampleName: "sample",
                pairedEnd: pairedEnd,
                threads: 1
            ),
            explicitLayout: explicitLayout,
            materializer: FASTQCLIMaterializer(runner: .shared)
        )
    }

    private func makeBundle(_ name: String) throws -> URL {
        let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func saveDerivedManifest(
        in bundle: URL,
        name: String,
        rootFile: String,
        payload: FASTQDerivativePayload,
        kind: FASTQDerivativeOperationKind,
        pairing: IngestionMetadata.PairingMode
    ) throws {
        let operation = FASTQDerivativeOperation(kind: kind)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name,
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: rootFile,
                payload: payload,
                lineage: [operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: 2, baseCount: 20),
                pairingMode: pairing,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
    }

    private static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }
}
