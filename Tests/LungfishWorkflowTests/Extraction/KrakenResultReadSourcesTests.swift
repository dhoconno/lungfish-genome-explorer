// KrakenResultReadSourcesTests.swift - Which read files a Kraken2 result's extraction and BLAST read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// D7a, D7b and D8, Phase 1.5 lane A3. The app's extraction and BLAST and
// their lungfish-cli commands resolve a result's read files through
// KrakenResultReadSources alone.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class KrakenResultReadSourcesTests: XCTestCase {
    private var root: URL!
    private var shapes: Kraken2ResultShapes!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-result-read-sources")
        shapes = try Kraken2ResultShapes(in: root, names: .slash)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private var scratch: URL { root.appendingPathComponent("scratch", isDirectory: true) }

    private func sources(_ resultDirectory: URL) async throws -> KrakenResultReadSources {
        try await KrakenResultReadSources.resolve(
            result: try ClassificationResult.load(from: resultDirectory),
            materializationDirectory: scratch
        )
    }

    private func roles(_ sources: KrakenResultReadSources) -> [String] {
        sources.files.map { "\($0.url.lastPathComponent):\($0.role.rawValue)" }
    }

    // MARK: - Bundles

    func testABundleGivesItsFilesByRolePairsFirst() async throws {
        let paired = try await sources(shapes.pairedDerivativeResult)
        XCTAssertEqual(roles(paired), ["sample_R1.fastq:r1", "sample_R2.fastq:r2"])
        XCTAssertEqual(paired.inputs, [shapes.fixtures.pairedDerivative.standardizedFileURL])

        let merge = try await sources(shapes.mergeDerivativeResult)
        XCTAssertEqual(roles(merge), ["unmerged_R1.fastq:r1", "unmerged_R2.fastq:r2", "merged.fastq:reads"])
        XCTAssertEqual(merge.files.last?.singleReadRole, .merged)
        XCTAssertEqual(merge.inputs, [shapes.fixtures.mergeDerivative.standardizedFileURL],
                       "the bundle's own merged file is not recorded again as an input")
    }

    func testAMixedOrInterleavedFileIsReadAsItIs() async throws {
        let mixed = try Kraken2ResultShapes.result(
            "mixed-only", in: shapes.analyses, inputs: [shapes.fixtures.mixedRoot], paired: true, lines: []
        )
        let mixedSources = try await sources(mixed)
        XCTAssertEqual(roles(mixedSources), ["reads.fastq:adjacentMates"])

        let single = try Kraken2ResultShapes.result(
            "single-only", in: shapes.analyses, inputs: [shapes.fixtures.singleRoot], paired: false, lines: []
        )
        let singleSources = try await sources(single)
        XCTAssertEqual(roles(singleSources), ["single.fastq:reads"])
        XCTAssertFalse(singleSources.holdsMates)
    }

    // MARK: - Virtual derivatives

    func testASubsetReadsTheFilesItsReadsComeFrom() async throws {
        let ofMerge = try Kraken2ResultShapes.result(
            "subset-of-merge", in: shapes.analyses, inputs: [shapes.fixtures.subsetOfMerge], paired: true, lines: []
        )
        let ofMergeSources = try await sources(ofMerge)
        XCTAssertEqual(roles(ofMergeSources), ["unmerged_R1.fastq:r1", "unmerged_R2.fastq:r2", "merged.fastq:reads"])

        let ofSingle = try Kraken2ResultShapes.result(
            "subset-of-single", in: shapes.analyses, inputs: [shapes.fixtures.subsetOfSingle], paired: false, lines: []
        )
        let ofSingleSources = try await sources(ofSingle)
        XCTAssertEqual(roles(ofSingleSources), ["single.fastq:reads"], "never the subset's preview")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "a plain subset is not materialized")
    }

    func testAnOrientedSubsetIsMaterializedOnce() async throws {
        let result = try shapes.orientedSubsetResult()
        let resolved = try await sources(result)
        let file = try XCTUnwrap(resolved.files.first)
        XCTAssertEqual(resolved.files.count, 1)
        XCTAssertEqual(file.url.deletingLastPathComponent(), scratch.standardizedFileURL)
        XCTAssertTrue(try String(contentsOf: file.url, encoding: .utf8).contains("@s2\nCCGGGGTTTT\n"), "s2 reverse-complemented")
    }

    // MARK: - Loose files

    func testTwoLooseFilesArePairedOnlyWhenKraken2ClassifiedPairs() async throws {
        let loose = shapes.fixtures.projectURL.appendingPathComponent("loose", isDirectory: true)
        let r1 = loose.appendingPathComponent("sample_R1.fastq")
        let r2 = loose.appendingPathComponent("sample_R2.fastq")

        let paired = try Kraken2ResultShapes.result(
            "loose-paired", in: shapes.analyses, inputs: [r1, r2], paired: true,
            lines: [Kraken2ResultShapes.pair("q1", 100)]
        )
        let pairedSources = try await sources(paired)
        XCTAssertEqual(roles(pairedSources), ["sample_R1.fastq:r1", "sample_R2.fastq:r2"])

        let unpaired = try Kraken2ResultShapes.result(
            "loose-unpaired", in: shapes.analyses, inputs: [r1, r2], paired: false,
            lines: [Kraken2ResultShapes.single("q1/1", 100), Kraken2ResultShapes.single("q1/2", 100)]
        )
        let unpairedSources = try await sources(unpaired)
        XCTAssertEqual(roles(unpairedSources), ["sample_R1.fastq:reads", "sample_R2.fastq:reads"])

        let empty = try Kraken2ResultShapes.result("loose-empty", in: shapes.analyses, inputs: [r1, r2], paired: true, lines: [])
        let emptySources = try await sources(empty)
        XCTAssertEqual(roles(emptySources), ["sample_R1.fastq:reads", "sample_R2.fastq:reads"],
                       "an empty per-read output shows no pairs")
    }

    func testALoosePairAddsItsUnpairedFilesButNeverAScratchSplit() async throws {
        let loose = shapes.fixtures.projectURL.appendingPathComponent("loose", isDirectory: true)
        let r1 = loose.appendingPathComponent("sample_R1.fastq")
        let r2 = loose.appendingPathComponent("sample_R2.fastq")
        let merged = loose.appendingPathComponent("merged.fastq")
        let directory = shapes.analyses.appendingPathComponent("kraken2-loose-scratch", isDirectory: true)
        let split = directory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
            .appendingPathComponent("reads-1234.single.fastq")
        try FileManager.default.createDirectory(at: split.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["z1"]).write(to: split, atomically: true, encoding: .utf8)
        let config = Kraken2ResultShapes.config(inputs: [r1, r2], paired: true, singleReadFiles: [merged, split], in: directory)
        let result = try Kraken2ResultShapes.result("loose-scratch", in: shapes.analyses, config: config, lines: [Kraken2ResultShapes.pair("q1", 100)])

        let resolved = try await sources(result)
        XCTAssertEqual(resolved.inputs.map(\.lastPathComponent), ["sample_R1.fastq", "sample_R2.fastq", "merged.fastq"])
        XCTAssertEqual(roles(resolved), ["sample_R1.fastq:r1", "sample_R2.fastq:r2", "merged.fastq:reads"])
    }

    func testAScratchInputIsNeverASource() async throws {
        let directory = shapes.analyses.appendingPathComponent("kraken2-scratch-only", isDirectory: true)
        let split = directory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
            .appendingPathComponent("reads.R1.fastq")
        try FileManager.default.createDirectory(at: split.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["z1/1"]).write(to: split, atomically: true, encoding: .utf8)
        var config = Kraken2ResultShapes.config(inputs: [split], paired: false, in: directory)
        config.originalInputFiles = [root.appendingPathComponent("gone.lungfishfastq", isDirectory: true)]
        let result = try Kraken2ResultShapes.result("scratch-only", in: shapes.analyses, config: config, lines: [])

        do {
            _ = try await sources(result)
            XCTFail("a result whose only reads are a scratch split has no source")
        } catch ClassifierExtractionError.kraken2SourceMissing {
        }
    }

    // MARK: - The recorded inputs resolve to the same files

    func testTheRecordedInputsResolveToTheResultsFiles() async throws {
        for resultDirectory in [shapes.pairedDerivativeResult, shapes.mergeDerivativeResult] {
            let result = try ClassificationResult.load(from: resultDirectory)
            let fromResult = try await KrakenResultReadSources.resolve(result: result, materializationDirectory: scratch)
            let fromInputs = try await KrakenResultReadSources.resolve(
                inputs: try KrakenResultReadSources.recordedInputs(of: result),
                classificationOutput: result.outputURL,
                materializationDirectory: scratch
            )
            XCTAssertEqual(fromInputs, fromResult)
        }
    }
}
