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

    // MARK: - One file per input

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
        XCTAssertNil(resolved.pooledLayoutResolution)
        XCTAssertFalse(FileManager.default.fileExists(atPath: materializationDirectory.path))
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

    func testFullFASTABundleResolvesToItsFASTAInPlace() async throws {
        let bundle = try makeBundle("converted")
        let fasta = bundle.appendingPathComponent("converted.fasta")
        try ">f1\nACGTACGTAC\n>f2\nACGTACGTAC\n".write(to: fasta, atomically: true, encoding: .utf8)
        try saveDerivedManifest(
            in: bundle,
            name: "converted",
            rootFile: "converted.fasta",
            payload: .fullFASTA(fastaFilename: "converted.fasta"),
            kind: .translate,
            pairing: .singleEnd,
            format: .fasta
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

    // MARK: - Several files per input

    func testMultiFileBundleResolvesToEveryChunkAlignedToTheBundle() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("multi", chunks: [["m1", "m2"], ["m3"]])

        let resolved = try await resolve([bundle])

        XCTAssertEqual(resolved.executionInputURLs, chunks.map(\.standardizedFileURL))
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL, bundle.standardizedFileURL])
        XCTAssertFalse(resolved.didMaterialize)
        XCTAssertNil(resolved.pooledLayoutResolution)
    }

    func testMultiFileBundleIsConcatenatedForAMapperWithEveryReadInOrder() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("multi", chunks: [["m1", "m2"], ["m3", "m4", "m5"]])

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        let executionURL = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(resolved.executionInputURLs.count, 1, "the mapper receives one file")
        XCTAssertEqual(executionURL.deletingLastPathComponent().standardizedFileURL, materializationDirectory.standardizedFileURL)
        XCTAssertEqual(executionURL.pathExtension, "fastq")
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: executionURL), ["m1", "m2", "m3", "m4", "m5"])
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL])
        XCTAssertEqual(resolved.inputs.first?.concatenatedFrom, chunks.map(\.standardizedFileURL))
        XCTAssertTrue(resolved.didMaterialize)
        XCTAssertNotNil(resolved.materializationStartedAt)
        XCTAssertNotNil(resolved.materializationEndedAt)

        let concatenation = try XCTUnwrap(SequenceInputConcatenation.load(for: executionURL))
        XCTAssertEqual(concatenation.memberURLs, chunks.map(\.standardizedFileURL))
        XCTAssertEqual(concatenation.bundleURL, bundle.standardizedFileURL)
        XCTAssertEqual(concatenation.outputURL, executionURL)

        let layout = try XCTUnwrap(resolved.pooledLayoutResolution)
        XCTAssertEqual(layout.layout, .singleEnd)
        XCTAssertEqual(layout.source, .pooledFiles)
        XCTAssertEqual(layout.reason, "2 input files are pooled as single reads.")
    }

    func testChunksWithoutATrailingNewlineStayApartWhenConcatenated() async throws {
        let (bundle, _) = try makeMultiFileBundle("multi", chunks: [["m1"], ["m2"]], trailingNewline: false)

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        let executionURL = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: executionURL), ["m1", "m2"])
    }

    func testGzippedChunksConcatenateIntoOneGzipStream() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("multi", chunks: [["g1", "g2"], ["g3"]], gzipped: true)
        XCTAssertTrue(chunks.allSatisfy { $0.pathExtension == "gz" })

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        let executionURL = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(executionURL.lastPathComponent.hasSuffix(".fastq.gz"), true)
        XCTAssertEqual(try Self.gunzippedReadNames(of: executionURL), ["g1", "g2", "g3"])
    }

    func testChunksMixingCompressionAreRefused() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("multi", chunks: [["x1"], ["x2"]])
        try Self.gzip(chunks[1])
        try FASTQSourceFileManifest(files: [
            .init(filename: "chunks/\(chunks[0].lastPathComponent)", originalPath: "/orig/0", sizeBytes: 1, isSymlink: false),
            .init(filename: "chunks/\(chunks[1].lastPathComponent).gz", originalPath: "/orig/1", sizeBytes: 1, isSymlink: false),
        ]).save(to: bundle)

        await XCTAssertThrowsErrorAsync(try await resolve([bundle], concatenateUnpairedFiles: true)) { error in
            guard case ResolvedSequenceInputsError.mixedCompression = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: materializationDirectory.path))
    }

    func testTwoChunksNamedAsMatesStayApartAsR1AndR2() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("pairimport", chunks: [["p1/1"], ["p1/2"]], names: ["sample_R2.fastq", "sample_R1.fastq"])

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        // R1 first, whatever order the files were listed in.
        XCTAssertEqual(
            resolved.executionInputURLs.map(\.lastPathComponent),
            ["sample_R1.fastq", "sample_R2.fastq"]
        )
        XCTAssertEqual(Set(resolved.executionInputURLs), Set(chunks.map(\.standardizedFileURL)))
        XCTAssertTrue(resolved.resolvedAsMatePair)
        XCTAssertFalse(resolved.didMaterialize)
        XCTAssertNil(resolved.pooledLayoutResolution)
    }

    func testFullPairedBundleResolvesToBothMatesAlignedToTheBundle() async throws {
        let bundle = try makeBundle("paired")
        let r1 = bundle.appendingPathComponent("sample_R1.fastq")
        let r2 = bundle.appendingPathComponent("sample_R2.fastq")
        try Self.fastq(["p1/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(["p1/2"]).write(to: r2, atomically: true, encoding: .utf8)
        try saveDerivedManifest(
            in: bundle,
            name: "paired",
            rootFile: "sample_R1.fastq",
            payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
            kind: .interleaveReformat,
            pairing: .pairedEnd
        )

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        XCTAssertEqual(resolved.executionInputURLs, [r1.standardizedFileURL, r2.standardizedFileURL])
        XCTAssertEqual(resolved.originalInputURLs, [bundle.standardizedFileURL, bundle.standardizedFileURL])
        XCTAssertTrue(resolved.resolvedAsMatePair)
        XCTAssertFalse(resolved.didMaterialize)
    }

    func testFullPairedBundleWithUnconventionalNamesIsStillAMatePairFromItsManifest() async throws {
        let bundle = try makeBundle("paired")
        let left = bundle.appendingPathComponent("left.fastq")
        let right = bundle.appendingPathComponent("right.fastq")
        try Self.fastq(["p1/1"]).write(to: left, atomically: true, encoding: .utf8)
        try Self.fastq(["p1/2"]).write(to: right, atomically: true, encoding: .utf8)
        try saveDerivedManifest(
            in: bundle,
            name: "paired",
            rootFile: "right.fastq",
            payload: .fullPaired(r1Filename: "right.fastq", r2Filename: "left.fastq"),
            kind: .interleaveReformat,
            pairing: .pairedEnd
        )

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        // The manifest's R1 comes first, not the alphabetical file.
        XCTAssertEqual(resolved.executionInputURLs, [right.standardizedFileURL, left.standardizedFileURL])
        XCTAssertTrue(resolved.resolvedAsMatePair)
    }

    func testFullMixedBundleIsConcatenatedAsSingleReads() async throws {
        let bundle = try makeBundle("mixed")
        let merged = bundle.appendingPathComponent("merged.fastq")
        let r1 = bundle.appendingPathComponent("unmerged_R1.fastq")
        let r2 = bundle.appendingPathComponent("unmerged_R2.fastq")
        try Self.fastq(["x1", "x2", "x3"]).write(to: merged, atomically: true, encoding: .utf8)
        try Self.fastq(["u1/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try Self.fastq(["u1/2"]).write(to: r2, atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: 3),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: 1),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: 1),
        ])
        try saveDerivedManifest(
            in: bundle,
            name: "mixed",
            rootFile: "merged.fastq",
            payload: .fullMixed(classification),
            kind: .pairedEndMerge,
            pairing: .pairedEnd,
            classification: classification
        )

        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)

        let executionURL = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(resolved.executionInputURLs.count, 1)
        XCTAssertEqual(try DerivedFASTQBundleFixture.readNames(in: executionURL), ["x1", "x2", "x3", "u1/1", "u1/2"])
        XCTAssertEqual(
            resolved.inputs.first?.concatenatedFrom,
            [merged, r1, r2].map(\.standardizedFileURL)
        )
        XCTAssertFalse(resolved.resolvedAsMatePair)
        XCTAssertEqual(resolved.pooledLayoutResolution?.layout, .singleEnd)
        XCTAssertEqual(resolved.pooledLayoutResolution?.reason, "3 input files are pooled as single reads.")
    }

    // MARK: - Failure

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

    // MARK: - Lineage on the request and in provenance

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

    func testPipelineRecordsTheConcatenationStepWithEveryChunkAsAnInput() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("multi", chunks: [["m1"], ["m2"]])
        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)
        let request = Self.request(inputFASTQURLs: [bundle])
            .withInputFASTQURLs(resolved.executionInputURLs, pairedEnd: false)
            .withInputLineage(resolved)
        let concatenated = resolved.executionInputURLs[0]

        let steps = try ManagedMappingPipeline().mappingInputMaterializationStepsForTesting(request: request)

        let step = try XCTUnwrap(steps.first)
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(step.toolName, SequenceInputConcatenation.toolName)
        XCTAssertEqual(step.command, try XCTUnwrap(SequenceInputConcatenation.load(for: concatenated)).command)
        XCTAssertEqual(step.durableReplayArgv, step.command)
        XCTAssertEqual(step.inputs.map(\.path), chunks.map { $0.standardizedFileURL.path })
        XCTAssertTrue(step.inputs.allSatisfy { $0.sha256 != nil && $0.sizeBytes != nil })
        XCTAssertEqual(step.outputs.map(\.path), [concatenated.path])
    }

    func testConcatenationIsADurableMaterializedInputForProvenance() async throws {
        let (bundle, chunks) = try makeMultiFileBundle("multi", chunks: [["m1"], ["m2"]])
        let resolved = try await resolve([bundle], concatenateUnpairedFiles: true)
        let concatenated = resolved.executionInputURLs[0]

        let pairs = CLISequenceInputMaterialization.materializedInputPairs(
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs
        )
        XCTAssertEqual(pairs, [CLISequenceInputMaterializationPair(originalURL: bundle, executionURL: concatenated)])

        let records = try CLISequenceInputMaterialization.inputRecordsPreservingLineage(
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs
        )
        let recordedPaths = Set(records.map(\.path))
        for chunk in chunks {
            XCTAssertTrue(recordedPaths.contains(chunk.standardizedFileURL.path), "provenance omits \(chunk.lastPathComponent)")
        }
        XCTAssertTrue(recordedPaths.contains(concatenated.path))

        let argv = ["lungfish-cli", "map", bundle.path, "--reference", "/tmp/reference.fa"]
        XCTAssertEqual(
            CLISequenceInputMaterialization.durableReplayArgv(
                argv: argv,
                originalInputURLs: resolved.originalInputURLs,
                executionInputURLs: resolved.executionInputURLs
            ),
            ["lungfish-cli", "map", concatenated.path, "--reference", "/tmp/reference.fa"]
        )

        CLISequenceInputMaterialization.cleanupMaterializedOutputs(
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: concatenated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: SequenceInputConcatenation.sidecarURL(for: concatenated).path))
    }

    // MARK: - Helpers

    private func resolve(_ inputURLs: [URL], concatenateUnpairedFiles: Bool = false) async throws -> ResolvedSequenceInputs {
        try await ResolvedSequenceInputs.resolve(
            inputURLs: inputURLs,
            materializationDirectory: materializationDirectory,
            materializer: FASTQCLIMaterializer(runner: .shared),
            concatenateUnpairedFiles: concatenateUnpairedFiles
        )
    }

    private func makeBundle(_ name: String) throws -> URL {
        let url = imports.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A root bundle whose `source-files.json` lists one chunk file per entry
    /// of `chunks`, named `run_<index>.fastq` unless `names` says otherwise.
    private func makeMultiFileBundle(
        _ name: String,
        chunks: [[String]],
        names: [String]? = nil,
        gzipped: Bool = false,
        trailingNewline: Bool = true
    ) throws -> (bundle: URL, chunks: [URL]) {
        let bundle = try makeBundle(name)
        let chunkDirectory = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        var urls: [URL] = []
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for (index, reads) in chunks.enumerated() {
            let fileName = names?[index] ?? "run_\(index).fastq"
            var url = chunkDirectory.appendingPathComponent(fileName)
            var text = Self.fastq(reads)
            if !trailingNewline { text.removeLast() }
            try text.write(to: url, atomically: true, encoding: .utf8)
            if gzipped {
                try Self.gzip(url)
                url = URL(fileURLWithPath: url.path + ".gz")
            }
            urls.append(url)
            entries.append(.init(
                filename: "chunks/\(url.lastPathComponent)",
                originalPath: "/orig/\(url.lastPathComponent)",
                sizeBytes: 1,
                isSymlink: false
            ))
        }
        try Self.fastq([chunks[0][0]]).write(to: bundle.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        return (bundle, urls)
    }

    private func saveDerivedManifest(
        in bundle: URL,
        name: String,
        rootFile: String,
        payload: FASTQDerivativePayload,
        kind: FASTQDerivativeOperationKind,
        pairing: IngestionMetadata.PairingMode,
        format: SequenceFormat = .fastq,
        classification: ReadClassification? = nil
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
                readClassification: classification,
                sequenceFormat: format
            ),
            in: bundle
        )
    }

    private static func fastq(_ names: [String]) -> String {
        names.map { "@\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
    }

    /// Replaces `url` with `url.gz` through the system gzip.
    private static func gzip(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-f", url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip failed for \(url.lastPathComponent)")
    }

    /// The read names in a gzip FASTQ, read back through the system gzip, so
    /// a multi-member stream is checked by a reader other than ours.
    private static func gunzippedReadNames(of url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip -dc failed for \(url.lastPathComponent)")
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
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
