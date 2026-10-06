// Kraken2ResultSourcesExtractionTests.swift - A Kraken2 taxon extraction reads every read file of its result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 1.5 lane A3, defects D7a to D7e. Lane A2 classifies the pairs of a
// sample as pairs and its merged or single reads beside them. Extracting a
// taxon from such a result must return both mates of each classified pair,
// the merged read of each merged fragment and each orphan, and nothing else,
// whatever convention names the mates.

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class Kraken2ResultSourcesExtractionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken2-result-sources")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - D7a, D7b, D7c: every shape and every mate-naming convention

    func testEachShapeExtractsBothMatesTheMergedReadsAndTheOrphansOfATaxon() async throws {
        for names in MateNames.allCases {
            let shapes = try Kraken2ResultShapes(in: root.appendingPathComponent(names.rawValue), names: names)
            for shape in shapes.all {
                let extracted = await extractedNames(shape.result)
                XCTAssertEqual(extracted, shape.expected, "\(shape.name), \(names.rawValue) mate names")
            }
        }
    }

    /// The bbmerge fixture of lane A2 as a merge derivative: 23 unmerged
    /// pairs and 77 merged reads, every fragment classified to the taxon.
    func testEveryFragmentOfARealMergeDerivativeIsExtractedPairsFirst() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .identical)
        let fixture = try shapes.bbmergeResult()
        let extracted = await extractedNames(fixture.result)

        XCTAssertEqual(extracted.count, 123, "23 pairs as 46 mates and 77 merged reads, not the 77 merged reads alone")
        let mates = Array(extracted.prefix(46))
        XCTAssertEqual(mates, fixture.pairNames.flatMap { [$0.r1, $0.r2] }, "each R1 record followed by its R2 record")
        XCTAssertEqual(Array(extracted.dropFirst(46)), fixture.mergedNames, "then the merged reads, in file order")
    }

    /// Loose R1 and R2 files classified with --paired, and a file of merged
    /// reads classified beside them with --unpaired. The taxon's only read is
    /// the merged y1, which sits in that separate single-read file. It is
    /// extracted, and nothing else, whatever names the mates carry.
    func testAMergedReadClassifiedFromASeparateSingleReadFileIsExtracted() async throws {
        for names in MateNames.allCases {
            let shapes = try Kraken2ResultShapes(in: root.appendingPathComponent(names.rawValue), names: names)
            let loose = shapes.fixtures.projectURL.appendingPathComponent("loose", isDirectory: true)
            let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
            let result = try Kraken2ResultShapes.result(
                "merged-only", in: shapes.analyses,
                inputs: [loose.appendingPathComponent("sample_R1.fastq"), loose.appendingPathComponent("sample_R2.fastq")],
                paired: true,
                singleReadFiles: [loose.appendingPathComponent("merged.fastq")],
                lines: [Kraken2ResultShapes.pair("q1", o), Kraken2ResultShapes.pair("q2", o), Kraken2ResultShapes.staged("y1", t), Kraken2ResultShapes.staged("y2", o)]
            )

            let extracted = await extractedNames(result)
            XCTAssertEqual(extracted, ["y1"], "\(names.rawValue) mate names")

            let bundle = try await extractedBundle(result)
            let payload = try XCTUnwrap(Self.payload(in: bundle))
            XCTAssertEqual(FASTQMetadataStore.load(for: payload)?.ingestion?.pairingMode, .singleEnd, "one merged read holds no pair")
            XCTAssertNil(FASTQMetadataStore.load(for: payload)?.readClassification)
        }
    }

    /// Final review S3. `conda classify --read-format auto` naming the merged
    /// file of a merge derivative classifies the whole derivative, since the
    /// resolver plans the bundle that holds a named file. Extraction reads the
    /// same reads, the pair u1 and the merged x1, not the named file alone.
    func testAFileNamedInsideAMergeDerivativeIsReadAsItsBundle() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let merged = shapes.fixtures.mergeDerivative.appendingPathComponent("merged.fastq").standardizedFileURL
        let directory = shapes.analyses.appendingPathComponent("kraken2-named-file", isDirectory: true)
        var config = Kraken2ResultShapes.config(inputs: [merged], paired: false, in: directory)
        let plan = try await KrakenReadSetPlanner.plan(
            bundle: merged, materializedInputs: [merged],
            materializationDirectory: directory.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName)
        )
        XCTAssertTrue(try KrakenReadSetPlanner.apply(plan, to: &config))
        XCTAssertEqual(config.originalInputFiles, [merged], "the recorded command names the file")
        let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
        let result = try Kraken2ResultShapes.result("named-file", in: shapes.analyses, config: config, lines: [
            Kraken2ResultShapes.pair("u1", t), Kraken2ResultShapes.staged("x1", t),
            Kraken2ResultShapes.staged("x2", o), Kraken2ResultShapes.staged("x3", o),
        ])

        let extracted = await extractedNames(result)
        XCTAssertEqual(extracted, ["u1/1", "u1/2", "x1"])
        XCTAssertEqual(
            try KrakenResultReadSources.recordedInputs(of: ClassificationResult.load(from: result)),
            [shapes.fixtures.mergeDerivative.standardizedFileURL]
        )
    }

    /// Final review N1. In a paired run, and so for every merged read staged
    /// beside an empty mate, the pinned kraken2 drops only a final /1 or /2
    /// from a read's name, as KrakenReadSetConformanceTests pins. It keeps the
    /// merged M.5 and the SRA mates named P.7 whole, and it writes H#0/1 and
    /// H#0/2 as H#0. Extraction finds each by the name kraken2 wrote, and
    /// M.15 and P.17, of another taxon, are never taken for M.5 or P.7.
    func testAPairedRunsReadsAreFoundByTheNamesKraken2Wrote() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let loose = root.appendingPathComponent("paired-run-names", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let r1 = loose.appendingPathComponent("sample_R1.fastq")
        let r2 = loose.appendingPathComponent("sample_R2.fastq")
        let merged = loose.appendingPathComponent("merged.fastq")
        try ReadSetFixtures.fastq(["P.7", "P.17", "H#0/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["P.7", "P.17", "H#0/2"]).write(to: r2, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["M.15", "M.5"]).write(to: merged, atomically: true, encoding: .utf8)
        let (t, o) = (Kraken2ResultShapes.target, Kraken2ResultShapes.other)
        let result = try Kraken2ResultShapes.result(
            "paired-run-names", in: shapes.analyses, inputs: [r1, r2], paired: true, singleReadFiles: [merged],
            lines: [Kraken2ResultShapes.pair("P.7", t), Kraken2ResultShapes.pair("P.17", o), Kraken2ResultShapes.pair("H#0", t),
                    Kraken2ResultShapes.staged("M.15", o), Kraken2ResultShapes.staged("M.5", t)]
        )

        let extracted = await extractedNames(result)
        XCTAssertEqual(extracted, ["P.7", "P.7", "H#0/1", "H#0/2", "M.5"])
    }

    /// A single-end result whose read names end in /1 used to extract nothing.
    func testSingleEndReadsNamedWithAMateSuffixAreFound() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let extracted = await extractedNames(try shapes.slashNamedSingleEndResult())
        XCTAssertEqual(extracted, ["a/1", "c/1"])
    }

    /// An ONT import holds its reads in chunks. Every chunk is read.
    func testAChunkedRootIsReadChunkByChunk() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let extracted = await extractedNames(try shapes.chunkedRootResult())
        XCTAssertEqual(extracted, ["c1", "c3"], "c3 sits in the second chunk")
    }

    /// An oriented subset holds reverse-complemented reads. Its extraction
    /// returns them as kraken2 classified them, never the root's strand.
    func testAnOrientedSubsetExtractsTheOrientedReads() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let output = try await extractedFile(try shapes.orientedSubsetResult())
        let records = try String(contentsOf: try XCTUnwrap(output), encoding: .utf8)
        XCTAssertEqual(records, "@s2\nCCGGGGTTTT\n+\nJIHGFEDCBA\n", "s2 reverse-complemented, with its qualities reversed")
    }

    // MARK: - Unchanged shapes

    /// Single-end and interleaved results extract the records they did before,
    /// byte for byte, and record the pairing they did before.
    func testSingleEndAndInterleavedResultsExtractAsBefore() async throws {
        for names in [MateNames.identical, .casava] {
            let shapes = try Kraken2ResultShapes(in: root.appendingPathComponent(names.rawValue), names: names)
            for (result, expected, pairing) in try shapes.unchangedResults() {
                let output = try await extractedFile(result)
                XCTAssertEqual(try String(contentsOf: try XCTUnwrap(output), encoding: .utf8), expected, result.lastPathComponent)

                let bundle = try await extractedBundle(result)
                let payload = try XCTUnwrap(Self.payload(in: bundle))
                XCTAssertEqual(FASTQMetadataStore.load(for: payload)?.ingestion?.pairingMode, pairing, result.lastPathComponent)
                XCTAssertNil(FASTQMetadataStore.load(for: payload)?.readClassification, result.lastPathComponent)
            }
        }
    }

    // MARK: - D7d: output layout and its record

    func testAnOutOfStepR2FileFailsRatherThanMispairs() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .identical)
        let result = try shapes.swappedR2Result()
        do {
            _ = try await extractedFile(result)
            XCTFail("an R2 file whose records are out of step with R1 must stop the extraction")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("mateNameMismatch"),
                "expected a mate-name mismatch, got \(error)"
            )
        }
    }

    func testAnExtractedBundleRecordsPairsAsInterleavedAndAMixAsRoles() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .identical)

        let pairsOnly = try await extractedBundle(shapes.pairedDerivativeResult)
        let pairsPayload = try XCTUnwrap(Self.payload(in: pairsOnly))
        XCTAssertEqual(FASTQMetadataStore.load(for: pairsPayload)?.ingestion?.pairingMode, .interleaved)
        XCTAssertEqual(try Self.extractionParameters(in: pairsOnly)["classifierExtractionOutputPairingMode"], "interleaved")

        let mixed = try await extractedBundle(shapes.mergeDerivativeResult)
        let mixedPayload = try XCTUnwrap(Self.payload(in: mixed))
        let roles = try XCTUnwrap(FASTQMetadataStore.load(for: mixedPayload)?.readClassification, "a mix of pairs and merged reads records its roles")
        XCTAssertEqual(roles.files.map(\.role), [.pairedR1, .pairedR2, .merged])
        XCTAssertEqual(roles.files.map(\.readCount), [1, 1, 1])
        XCTAssertEqual(Set(roles.files.map(\.filename)), [mixedPayload.lastPathComponent])
        XCTAssertEqual(try Self.extractionParameters(in: mixed)["classifierExtractionOutputPairingMode"], "mixed")
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: mixed).layout, .mixedInterleaved)
    }

    // MARK: - D7e: batch extraction

    func testBatchExtractionReadsEverySourceFileIntoOneFilePerTaxon() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let result = try ClassificationResult.load(from: shapes.mergeDerivativeResult)
        let collection = TaxaCollection(
            id: "a3-batch",
            name: "A3 batch",
            description: "",
            sfSymbol: "circle",
            taxa: [TaxonTarget(name: "Target virus", taxId: 100)]
        )
        let outputDirectory = root.appendingPathComponent("batch", isDirectory: true)

        let outputs: [URL]
        do {
            outputs = try await TaxonomyExtractionPipeline().extractBatch(
                collection: collection,
                classificationResult: result,
                tree: result.tree,
                outputDirectory: outputDirectory
            )
        } catch {
            return XCTFail("batch extraction failed: \(error)")
        }

        XCTAssertEqual(outputs.count, 1, "one file per taxon")
        let names = try outputs.flatMap { try Self.recordNames(in: $0) }
        XCTAssertEqual(names, ["u1/1", "u1/2", "x1"])

        let output = try XCTUnwrap(outputs.first)
        XCTAssertEqual(output.lastPathComponent, "Target_virus_taxid100.fastq.gz", "the name a one-file extraction writes")
        let roles = try XCTUnwrap(FASTQMetadataStore.load(for: output)?.readClassification, "a mix of pairs and merged reads records its roles")
        XCTAssertEqual(roles.files.map(\.role), [.pairedR1, .pairedR2, .merged])
        XCTAssertEqual(Set(roles.files.map(\.filename)), [output.lastPathComponent])
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: output)))
        XCTAssertEqual(envelope.options.explicit["extractedReads"], .integer(3), "the records of the one file")
        XCTAssertEqual(Array(envelope.steps.first?.argv.prefix(2) ?? []), ["LungfishWorkflow", "extract-taxon-reads"])
    }

    /// A result of one loose file is extracted as before: one gzip file per
    /// taxon, straight from seqkit.
    func testBatchExtractionOfOneFileIsUnchanged() async throws {
        let shapes = try Kraken2ResultShapes(in: root, names: .slash)
        let file = shapes.fixtures.projectURL.appendingPathComponent("loose-single.fastq")
        try ReadSetFixtures.fastq(["s1", "s2", "s3"]).write(to: file, atomically: true, encoding: .utf8)
        let resultDirectory = try Kraken2ResultShapes.result(
            "loose-single", in: shapes.analyses, inputs: [file], paired: false,
            lines: [Kraken2ResultShapes.single("s1", 100), Kraken2ResultShapes.single("s2", 200), Kraken2ResultShapes.single("s3", 100)]
        )
        let result = try ClassificationResult.load(from: resultDirectory)
        let collection = TaxaCollection(
            id: "a3-batch-single", name: "A3 batch", description: "", sfSymbol: "circle",
            taxa: [TaxonTarget(name: "Target virus", taxId: 100)]
        )

        let outputs = try await TaxonomyExtractionPipeline().extractBatch(
            collection: collection,
            classificationResult: result,
            tree: result.tree,
            outputDirectory: root.appendingPathComponent("batch-single", isDirectory: true)
        )

        XCTAssertEqual(outputs.map(\.lastPathComponent), ["Target_virus_taxid100.fastq.gz"])
        XCTAssertEqual(try outputs.flatMap { try Self.recordNames(in: $0) }, ["s1", "s3"])
        XCTAssertNil(FASTQMetadataStore.load(for: try XCTUnwrap(outputs.first)), "a one-file output gains no sidecar")
    }

    // MARK: - Helpers

    private func extractedFile(_ result: URL) async throws -> URL? {
        let output = root.appendingPathComponent("out-\(UUID().uuidString).fastq")
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: result,
            selections: [ClassifierRowSelector(taxIds: [Kraken2ResultShapes.target])],
            options: ExtractionOptions(),
            destination: .file(output)
        )
        guard case .file(let url, _) = outcome else { return nil }
        return url
    }

    private func extractedBundle(_ result: URL) async throws -> URL {
        let projectRoot = ClassifierReadResolver.resolveProjectRoot(from: result)
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: result,
            selections: [ClassifierRowSelector(taxIds: [Kraken2ResultShapes.target])],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: projectRoot,
                displayName: "a3-\(result.lastPathComponent)-\(UUID().uuidString.prefix(6))",
                metadata: ExtractionMetadata(sourceDescription: "a3", toolName: "Kraken2", parameters: [:])
            )
        )
        // Another outcome is a dispatch regression, so it fails the test
        // rather than skip it (final review B note 11).
        let url: URL? = if case .bundle(let url, _) = outcome { url } else { nil }
        return try XCTUnwrap(url, "expected a bundle outcome, got \(outcome)")
    }

    /// The record names an extraction writes, or the error it threw, so a
    /// failing assertion shows what came out.
    private func extractedNames(_ result: URL) async -> [String] {
        do {
            guard let url = try await extractedFile(result) else { return ["<no file>"] }
            return try Self.recordNames(in: url)
        } catch {
            return ["<threw \(error)>"]
        }
    }

    static func recordNames(in url: URL) throws -> [String] {
        let text: String
        if url.pathExtension == "gz" {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            process.arguments = ["-dc", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, line in index % 4 == 0 && line.hasPrefix("@") ? String(line.dropFirst()) : nil }
    }

    static func payload(in bundle: URL) -> URL? {
        try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "fastq" }
    }

    static func extractionParameters(in bundle: URL) throws -> [String: String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            ExtractionMetadata.self,
            from: Data(contentsOf: bundle.appendingPathComponent("extraction-metadata.json"))
        ).parameters
    }
}

// MARK: - Fixture

/// How the two mates of a pair are named.
enum MateNames: String, CaseIterable {
    /// `p1/1` and `p1/2`.
    case slash
    /// `p1` and `p1`, the BBTools and SRA form.
    case identical
    /// `p1 1:N:0:ACGT` and `p1 2:N:0:ACGT`.
    case casava

    func name(_ fragment: String, mate: Int) -> String {
        switch self {
        case .slash: return "\(fragment)/\(mate)"
        case .identical: return fragment
        case .casava: return "\(fragment) \(mate):N:0:ACGT"
        }
    }

    /// Rewrites every `/1` and `/2` mate name in the FASTQ files directly
    /// inside `directory` to this convention.
    func apply(to directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "fastq" && $0.lastPathComponent != "preview.fastq" }
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            let renamed = lines.enumerated().map { index, line -> String in
                guard index % 4 == 0, line.hasPrefix("@"), line.count > 3 else { return line }
                let id = String(line.dropFirst())
                guard let mate = Int(String(id.suffix(1))), id.dropLast().hasSuffix("/"), mate == 1 || mate == 2 else { return line }
                return "@" + name(String(id.dropLast(2)), mate: mate)
            }
            try renamed.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }
}

/// Kraken2 results over the `ReadSetFixtures` layouts, each with the
/// per-read lines lane A2's run writes: a pair as `L|L`, a merged or single
/// read staged beside an empty mate as `L|0`, a single-end read as `L`.
/// Taxon 100 is the one extracted, taxon 200 is another.
struct Kraken2ResultShapes {
    static let target = 100
    static let other = 200

    struct Shape {
        let name: String
        let result: URL
        let expected: [String]
    }

    let fixtures: ReadSetFixtures
    let names: MateNames
    let analyses: URL

    let pairedDerivativeResult: URL
    let mergeDerivativeResult: URL
    let all: [Shape]

    init(in directory: URL, names: MateNames) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixtures = try ReadSetFixtures(in: directory)
        self.names = names
        analyses = fixtures.projectURL.appendingPathComponent("Analyses", isDirectory: true)
        for bundle in [fixtures.pairedDerivative, fixtures.mergeDerivative, fixtures.repairDerivative, fixtures.mixedRoot, fixtures.interleavedRoot] {
            try names.apply(to: bundle)
        }
        func n(_ fragment: String, _ mate: Int) -> String { names.name(fragment, mate: mate) }
        let (t, o) = (Self.target, Self.other)

        pairedDerivativeResult = try Self.result(
            "paired", in: analyses, inputs: [fixtures.pairedDerivative], paired: true,
            lines: [Self.pair("p1", t), Self.pair("p2", o)]
        )
        mergeDerivativeResult = try Self.result(
            "merge", in: analyses, inputs: [fixtures.mergeDerivative], paired: true,
            lines: [Self.pair("u1", t), Self.staged("x1", t), Self.staged("x2", o), Self.staged("x3", o)]
        )
        let repair = try Self.result(
            "repair", in: analyses, inputs: [fixtures.repairDerivative], paired: true,
            lines: [Self.pair("r1", t), Self.pair("r2", o), Self.staged("o1", t)]
        )
        let mixedRoot = try Self.result(
            "mixed-root", in: analyses, inputs: [fixtures.mixedRoot], paired: true,
            lines: [Self.pair("p1", t), Self.pair("p2", o), Self.staged("m1", t), Self.staged("m2", o), Self.staged("m3", o)]
        )
        let subsetOfMerge = try Self.result(
            "merge-subset", in: analyses, inputs: [fixtures.subsetOfMerge], paired: true,
            lines: [Self.pair("u1", t), Self.staged("x1", t)]
        )
        let subsetOfSingle = try Self.result(
            "single-subset", in: analyses, inputs: [fixtures.subsetOfSingle], paired: false,
            lines: [Self.single("s1", t), Self.single("s3", t)]
        )

        // Loose files named with --paired and --unpaired.
        let loose = fixtures.projectURL.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        let r1 = loose.appendingPathComponent("sample_R1.fastq")
        let r2 = loose.appendingPathComponent("sample_R2.fastq")
        let merged = loose.appendingPathComponent("merged.fastq")
        try ReadSetFixtures.fastq(["q1/1", "q2/1"]).write(to: r1, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["q1/2", "q2/2"]).write(to: r2, atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq(["y1", "y2"]).write(to: merged, atomically: true, encoding: .utf8)
        try names.apply(to: loose)
        let loosePair = try Self.result(
            "loose-pair", in: analyses, inputs: [r1, r2], paired: true, singleReadFiles: [merged],
            lines: [Self.pair("q1", t), Self.pair("q2", o), Self.staged("y1", t), Self.staged("y2", o)]
        )

        all = [
            Shape(name: "L5b paired derivative", result: pairedDerivativeResult, expected: [n("p1", 1), n("p1", 2)]),
            Shape(name: "L5c merge derivative", result: mergeDerivativeResult, expected: [n("u1", 1), n("u1", 2), "x1"]),
            Shape(name: "L5d repair derivative", result: repair, expected: [n("r1", 1), n("r1", 2), "o1"]),
            Shape(name: "L3 mixed root file", result: mixedRoot, expected: ["m1", n("p1", 1), n("p1", 2)]),
            Shape(name: "L6 subset of a merge derivative", result: subsetOfMerge, expected: [n("u1", 1), n("u1", 2), "x1"]),
            Shape(name: "L6 subset of a single-end root", result: subsetOfSingle, expected: ["s1", "s3"]),
            Shape(name: "loose pair with --unpaired", result: loosePair, expected: [n("q1", 1), n("q1", 2), "y1"]),
        ]
    }

    /// The bbmerge fixture as a merge derivative, every fragment classified
    /// to the taxon, with the names of its pairs and merged reads.
    func bbmergeResult() throws -> (result: URL, pairNames: [(r1: String, r2: String)], mergedNames: [String]) {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/read-pairing/kraken2", isDirectory: true)
        let bundle = fixtures.importsURL.appendingPathComponent("bbmerge.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        for name in ["merged.fastq", "unmerged_R1.fastq", "unmerged_R2.fastq"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: bundle.appendingPathComponent(name))
        }
        let r1Names = try Kraken2ResultSourcesExtractionTests.recordNames(in: bundle.appendingPathComponent("unmerged_R1.fastq"))
        let r2Names = try Kraken2ResultSourcesExtractionTests.recordNames(in: bundle.appendingPathComponent("unmerged_R2.fastq"))
        let mergedNames = try Kraken2ResultSourcesExtractionTests.recordNames(in: bundle.appendingPathComponent("merged.fastq"))
        let roles = ReadClassification(files: [
            .init(filename: "merged.fastq", role: .merged, readCount: mergedNames.count),
            .init(filename: "unmerged_R1.fastq", role: .pairedR1, readCount: r1Names.count),
            .init(filename: "unmerged_R2.fastq", role: .pairedR2, readCount: r2Names.count),
        ])
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "bbmerge",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "merged.fastq",
                payload: .fullMixed(roles),
                lineage: [FASTQDerivativeOperation(kind: .pairedEndMerge)],
                operation: FASTQDerivativeOperation(kind: .pairedEndMerge),
                cachedStatistics: .placeholder(readCount: 123, baseCount: 0),
                pairingMode: .pairedEnd,
                readClassification: roles,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        func fragment(_ name: String) -> String { String(name.split(separator: " ")[0]) }
        let lines = r1Names.map { Self.pair(fragment($0), Self.target) }
            + mergedNames.map { Self.staged(fragment($0), Self.target) }
        let result = try Self.result("bbmerge", in: analyses, inputs: [bundle], paired: true, lines: lines)
        return (result, Array(zip(r1Names, r2Names)).map { (r1: $0.0, r2: $0.1) }, mergedNames)
    }

    /// A loose single-end file whose reads are named `a/1`, `b/1` and `c/1`.
    func slashNamedSingleEndResult() throws -> URL {
        let file = fixtures.projectURL.appendingPathComponent("single-end-slash.fastq")
        try ReadSetFixtures.fastq(["a/1", "b/1", "c/1"]).write(to: file, atomically: true, encoding: .utf8)
        return try Self.result(
            "single-end-slash", in: analyses, inputs: [file], paired: false,
            lines: [Self.single("a/1", Self.target), Self.single("b/1", Self.other), Self.single("c/1", Self.target)]
        )
    }

    /// The chunked root (run_0 holds c1 and c2, run_1 holds c3).
    func chunkedRootResult() throws -> URL {
        try Self.result(
            "chunked", in: analyses, inputs: [fixtures.chunkedRoot], paired: false,
            lines: [Self.single("c1", Self.target), Self.single("c2", Self.other), Self.single("c3", Self.target)]
        )
    }

    /// An orientation-map subset of a single-end root that reverse-complements
    /// s2. Its preview holds only s1, as a preview of a large dataset holds
    /// only its first reads.
    func orientedSubsetResult() throws -> URL {
        let rootBundle = fixtures.importsURL.appendingPathComponent("orient-root.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: rootBundle, withIntermediateDirectories: true)
        try "@s1\nACGTACGTAC\n+\nIIIIIIIIII\n@s2\nAAAACCCCGG\n+\nABCDEFGHIJ\n@s3\nACGTACGTAC\n+\nIIIIIIIIII\n"
            .write(to: rootBundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        let child = fixtures.importsURL.appendingPathComponent("orient-child.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try "s1\t+\ns2\t-\ns3\t+\n".write(to: child.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try "@s1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: child.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "orient-child",
                parentBundleRelativePath: "@/Imports/orient-root.lungfishfastq",
                rootBundleRelativePath: "@/Imports/orient-root.lungfishfastq",
                rootFASTQFilename: "reads.fastq",
                payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
                lineage: [FASTQDerivativeOperation(kind: .orient)],
                operation: FASTQDerivativeOperation(kind: .orient),
                cachedStatistics: .placeholder(readCount: 3, baseCount: 30),
                pairingMode: nil,
                sequenceFormat: .fastq
            ),
            in: child
        )
        return try Self.result(
            "orient-child", in: analyses, inputs: [child], paired: false,
            lines: [Self.single("s1", Self.other), Self.single("s2", Self.target), Self.single("s3", Self.other)]
        )
    }

    /// A paired derivative whose R2 file lists its fragments in the other order.
    func swappedR2Result() throws -> URL {
        let bundle = fixtures.importsURL.appendingPathComponent("swapped.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq([names.name("p1", mate: 1), names.name("p2", mate: 1)])
            .write(to: bundle.appendingPathComponent("sample_R1.fastq"), atomically: true, encoding: .utf8)
        try ReadSetFixtures.fastq([names.name("p2", mate: 2), names.name("p1", mate: 2)])
            .write(to: bundle.appendingPathComponent("sample_R2.fastq"), atomically: true, encoding: .utf8)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "swapped",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "sample_R1.fastq",
                payload: .fullPaired(r1Filename: "sample_R1.fastq", r2Filename: "sample_R2.fastq"),
                lineage: [FASTQDerivativeOperation(kind: .interleaveReformat)],
                operation: FASTQDerivativeOperation(kind: .interleaveReformat),
                cachedStatistics: .placeholder(readCount: 4, baseCount: 40),
                pairingMode: .pairedEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        return try Self.result(
            "swapped", in: analyses, inputs: [bundle], paired: true,
            lines: [Self.pair("p1", Self.target), Self.pair("p2", Self.target)]
        )
    }

    /// Results whose extraction is unchanged: a single-end root and an
    /// interleaved root, with the exact records each must extract and the
    /// pairing recorded on the extracted bundle.
    func unchangedResults() throws -> [(URL, String, IngestionMetadata.PairingMode)] {
        let single = try Self.result(
            "single", in: analyses, inputs: [fixtures.singleRoot], paired: false,
            lines: [Self.single("s1", Self.target), Self.single("s2", Self.other), Self.single("s3", Self.target)]
        )
        var interleavedConfig = Self.config(inputs: [fixtures.interleavedRoot], paired: false, in: analyses.appendingPathComponent("kraken2-interleaved"))
        interleavedConfig.interleavedInput = true
        let interleaved = try Self.result(
            "interleaved", in: analyses, config: interleavedConfig,
            lines: [Self.pair("i1", Self.target), Self.pair("i2", Self.other)]
        )
        return [
            (single, ReadSetFixtures.fastq(["s1", "s3"]), .singleEnd),
            (interleaved, ReadSetFixtures.fastq([names.name("i1", mate: 1), names.name("i1", mate: 2)]), .interleaved),
        ]
    }

    // MARK: Result writing

    static func pair(_ fragment: String, _ taxId: Int) -> String {
        "C\t\(fragment)\t\(taxId)\t10|10\t\(taxId):3 |:| \(taxId):3"
    }

    static func staged(_ fragment: String, _ taxId: Int) -> String {
        "C\t\(fragment)\t\(taxId)\t10|0\t\(taxId):3 |:| "
    }

    static func single(_ read: String, _ taxId: Int) -> String {
        "C\t\(read)\t\(taxId)\t10\t\(taxId):3"
    }

    static let kreport = """
     25.00\t1\t1\tU\t0\tunclassified
     75.00\t3\t0\tR\t1\troot
     50.00\t2\t2\tS\t100\t  Target virus
     25.00\t1\t1\tS\t200\t  Other virus

    """

    static func config(inputs: [URL], paired: Bool, singleReadFiles: [URL] = [], in directory: URL) -> ClassificationConfig {
        var config = ClassificationConfig(
            inputFiles: inputs,
            isPairedEnd: paired,
            databaseName: "Viral",
            databasePath: directory,
            outputDirectory: directory
        )
        config.originalInputFiles = inputs
        config.singleReadFiles = singleReadFiles
        return config
    }

    static func result(
        _ name: String,
        in analyses: URL,
        inputs: [URL],
        paired: Bool,
        singleReadFiles: [URL] = [],
        lines: [String]
    ) throws -> URL {
        let directory = analyses.appendingPathComponent("kraken2-\(name)", isDirectory: true)
        return try result(name, in: analyses, config: config(inputs: inputs, paired: paired, singleReadFiles: singleReadFiles, in: directory), lines: lines)
    }

    static func result(_ name: String, in analyses: URL, config: ClassificationConfig, lines: [String]) throws -> URL {
        let directory = config.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let kreportURL = directory.appendingPathComponent("classification.kreport")
        try kreport.write(to: kreportURL, atomically: true, encoding: .utf8)
        let krakenURL = directory.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: krakenURL, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: config,
            tree: try KreportParser.parse(url: kreportURL),
            reportURL: kreportURL,
            outputURL: krakenURL,
            brackenURL: nil,
            runtime: 1,
            toolVersion: "2.17.1",
            provenanceId: nil
        ).save(to: directory)
        return directory
    }
}
