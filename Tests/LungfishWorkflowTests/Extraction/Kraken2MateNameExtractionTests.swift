// Kraken2MateNameExtractionTests.swift - A Kraken2 extraction finds reads by the names kraken2 wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.1 lane L6, item 2. kraken2 --paired reads R1 and R2 by position
// and names a pair by its R1 read, dropping one final /1 or /2. So mates
// named x.1 and x.2 run as the pair x.1, and a merged read named x/1 staged
// beside an empty mate runs as x. Extraction used to look for x.1 in the R2
// file, check mates by the /1 and /2 rule only, and trim x/1/1 twice.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class Kraken2MateNameExtractionTests: XCTestCase {
    private var root: URL!
    private var analyses: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken2-mate-names")
        analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - x.1 and x.2 mates of R1 and R2 files

    func testDottedAndUnderscoreMatesOfR1AndR2FilesAreBothExtracted() async throws {
        for mark in [".", "_"] {
            let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
            let names = ["p1", "p2", "p3"]
            let pair = try loosePair(r1: names.map { "\($0)\(mark)1" }, r2: names.map { "\($0)\(mark)2" }, label: "mark\(mark)")
            let result = try Kraken2ResultShapes.result(
                "mark\(mark)", in: analyses, inputs: [pair.r1, pair.r2], paired: true,
                lines: [
                    Kraken2ResultShapes.pair("p1\(mark)1", t),
                    Kraken2ResultShapes.pair("p2\(mark)1", o),
                    Kraken2ResultShapes.pair("p3\(mark)1", t),
                ]
            )

            let extracted = await extractedNames(result)

            XCTAssertEqual(extracted, ["p1\(mark)1", "p1\(mark)2", "p3\(mark)1", "p3\(mark)2"], "mates named with \(mark)1 and \(mark)2")
        }
    }

    func testABatchExtractionTakesBothDottedMates() async throws {
        let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
        let pair = try loosePair(r1: ["p1.1", "p2.1"], r2: ["p1.2", "p2.2"], label: "batch")
        let merged = root.appendingPathComponent("loose-batch/merged.fastq")
        try ReadSetFixtures.fastq(["m1", "m2"]).write(to: merged, atomically: true, encoding: .utf8)
        let resultDirectory = try Kraken2ResultShapes.result(
            "batch", in: analyses, inputs: [pair.r1, pair.r2], paired: true, singleReadFiles: [merged],
            lines: [
                Kraken2ResultShapes.pair("p1.1", t), Kraken2ResultShapes.pair("p2.1", o),
                Kraken2ResultShapes.staged("m1", o), Kraken2ResultShapes.staged("m2", t),
            ]
        )
        let result = try ClassificationResult.load(from: resultDirectory)

        let outputs = try await TaxonomyExtractionPipeline().extractBatch(
            collection: TaxaCollection(
                id: "l6-dotted", name: "L6 dotted", description: "", sfSymbol: "circle",
                taxa: [TaxonTarget(name: "Target virus", taxId: t)]
            ),
            classificationResult: result,
            tree: result.tree,
            outputDirectory: root.appendingPathComponent("batch-out", isDirectory: true)
        )

        XCTAssertEqual(try outputs.flatMap { try Kraken2ResultSourcesExtractionTests.recordNames(in: $0) }, ["p1.1", "p1.2", "m2"])
    }

    /// The mate check still stops files that are out of step.
    func testDottedR1AndR2FilesOutOfStepFailRatherThanMispair() async throws {
        let t = Kraken2ResultShapes.target
        let pair = try loosePair(r1: ["p1.1", "p2.1"], r2: ["p2.2", "p1.2"], label: "swapped")
        let result = try Kraken2ResultShapes.result(
            "swapped", in: analyses, inputs: [pair.r1, pair.r2], paired: true,
            lines: [Kraken2ResultShapes.pair("p1.1", t), Kraken2ResultShapes.pair("p2.1", t)]
        )

        let extracted = await extractedNames(result)

        XCTAssertEqual(extracted.count, 1, "\(extracted)")
        XCTAssertTrue(extracted.first?.contains("mateNameMismatch") == true, "\(extracted)")
    }

    // MARK: - x/1 merged reads in a staged run

    /// A merged read named m1/1, staged beside an empty mate, runs as m1. An
    /// extraction of exact read IDs (`conda extract --no-read-pairs`) finds
    /// it by that name, as it finds m1/1 in a single-end run.
    func testAStagedRunsMergedReadNamedWithSlashOneIsFoundByItsExactID() async throws {
        let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
        let pair = try loosePair(r1: ["q1/1"], r2: ["q1/2"], label: "staged")
        let merged = root.appendingPathComponent("loose-staged/merged.fastq")
        try ReadSetFixtures.fastq(["m1/1", "m2/1"]).write(to: merged, atomically: true, encoding: .utf8)
        let result = try Kraken2ResultShapes.result(
            "staged", in: analyses, inputs: [pair.r1, pair.r2], paired: true, singleReadFiles: [merged],
            lines: [Kraken2ResultShapes.pair("q1", o), Kraken2ResultShapes.staged("m1", t), Kraken2ResultShapes.staged("m2", o)]
        )

        let exactOut = root.appendingPathComponent("exact-out", isDirectory: true)
        try FileManager.default.createDirectory(at: exactOut, withIntermediateDirectories: true)
        let outputs = try await TaxonomyExtractionPipeline().extract(
            config: TaxonomyExtractionConfig(
                taxIds: [t],
                includeChildren: false,
                sourceFiles: [merged],
                outputFiles: [exactOut.appendingPathComponent("m.fastq")],
                classificationOutput: result.appendingPathComponent("classification.kraken"),
                keepReadPairs: false
            ),
            tree: try ClassificationResult.load(from: result).tree
        )

        XCTAssertEqual(try outputs.flatMap { try Kraken2ResultSourcesExtractionTests.recordNames(in: $0) }, ["m1/1"])
    }

    /// kraken2 drops one final /1 or /2, so a merged read named h/1/1 runs as
    /// h/1. Extraction must not drop a second one.
    func testAStagedRunsNameIsNotTrimmedTwice() async throws {
        let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
        let pair = try loosePair(r1: ["q1/1"], r2: ["q1/2"], label: "twice")
        let merged = root.appendingPathComponent("loose-twice/merged.fastq")
        try ReadSetFixtures.fastq(["h/1/1", "h2/1/1"]).write(to: merged, atomically: true, encoding: .utf8)
        let result = try Kraken2ResultShapes.result(
            "twice", in: analyses, inputs: [pair.r1, pair.r2], paired: true, singleReadFiles: [merged],
            lines: [Kraken2ResultShapes.pair("q1", o), Kraken2ResultShapes.staged("h/1", t), Kraken2ResultShapes.staged("h2/1", o)]
        )

        let extracted = await extractedNames(result)

        XCTAssertEqual(extracted, ["h/1/1"])
    }

    // MARK: - Helpers

    private func loosePair(r1: [String], r2: [String], label: String) throws -> (r1: URL, r2: URL) {
        let loose = root.appendingPathComponent("loose-\(label)", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let r1URL = loose.appendingPathComponent("sample_R1.fastq")
        let r2URL = loose.appendingPathComponent("sample_R2.fastq")
        try ReadSetFixtures.fastq(r1).write(to: r1URL, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(r2).write(to: r2URL, atomically: true, encoding: .utf8)
        return (r1URL, r2URL)
    }

    /// The record names the app's extraction writes, or the error it threw.
    private func extractedNames(_ result: URL) async -> [String] {
        do {
            let output = root.appendingPathComponent("out-\(UUID().uuidString).fastq")
            let outcome = try await ClassifierReadResolver().resolveAndExtract(
                tool: .kraken2,
                resultPath: result,
                selections: [ClassifierRowSelector(taxIds: [Kraken2ResultShapes.target])],
                options: ExtractionOptions(),
                destination: .file(output)
            )
            guard case .file(let url, _) = outcome else { return ["<no file>"] }
            return try Kraken2ResultSourcesExtractionTests.recordNames(in: url)
        } catch {
            return ["<threw \(error)>"]
        }
    }
}
