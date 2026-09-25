// Kraken2InterleavedExtractionPairingTests.swift - Extracted bundles record the pairing they hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

/// Extracting a taxon from a Kraken 2 result whose source is one interleaved
/// paired FASTQ keeps both mates of every classified pair, in order. The
/// bundle used to be recorded as single-end regardless, so downstream tools
/// treated 886,221 pairs as 1,772,442 unrelated reads.
final class Kraken2InterleavedExtractionPairingTests: XCTestCase {

    private var projectRoot: URL!

    override func setUpWithError() throws {
        projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("K2Pairing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent(".lungfish"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectRoot)
    }

    private func makeResultFolder() throws -> URL {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/kraken2-bracken-reopen")
        let analyses = projectRoot.appendingPathComponent("Analyses")
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let resultDir = analyses.appendingPathComponent("kraken2-2026-09-24T23-36-28")
        try FileManager.default.copyItem(at: fixture, to: resultDir)
        return resultDir
    }

    private func extractSimplexvirusBundle(from resultDir: URL) async throws -> (URL, Int) {
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .kraken2,
            resultPath: resultDir,
            selections: [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [3050292])],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: projectRoot,
                displayName: "kraken2_Simplexvirus_humanalpha1",
                metadata: ExtractionMetadata(
                    sourceDescription: "kraken2_Simplexvirus_humanalpha1",
                    toolName: "Kraken2",
                    parameters: ["taxIds": "3050292"]
                )
            )
        )
        guard case .bundle(let bundleURL, let readCount) = outcome else {
            XCTFail("Expected .bundle outcome, got \(outcome)")
            throw XCTSkip("no bundle")
        }
        return (bundleURL, readCount)
    }

    private func payload(in bundleURL: URL) throws -> URL {
        try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "fastq" }
        )
    }

    private func extractionParameters(in bundleURL: URL) throws -> [String: String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            ExtractionMetadata.self,
            from: Data(contentsOf: bundleURL.appendingPathComponent("extraction-metadata.json"))
        ).parameters
    }

    func testExtractionFromInterleavedPairsRecordsInterleavedBundle() async throws {
        let resultDir = try makeResultFolder()
        let (bundleURL, readCount) = try await extractSimplexvirusBundle(from: resultDir)

        XCTAssertEqual(readCount, 4, "both mates of the two Simplexvirus pairs")
        let fastq = try payload(in: bundleURL)
        let headers = try String(contentsOf: fastq, encoding: .utf8)
            .split(separator: "\n")
            .enumerated()
            .filter { $0.offset % 4 == 0 }
            .map { String($0.element) }
        XCTAssertEqual(headers, ["@pair1 pair1/1", "@pair1 pair1/2", "@pair2 pair2/1", "@pair2 pair2/2"])

        let persisted = try XCTUnwrap(FASTQMetadataStore.load(for: fastq))
        XCTAssertEqual(persisted.ingestion?.pairingMode, .interleaved)
        XCTAssertEqual(try extractionParameters(in: bundleURL)["classifierExtractionOutputPairingMode"], "interleaved")

        // Downstream consumers see pairs, not unrelated reads.
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: bundleURL).layout, .strictlyInterleaved)
    }

    func testExtractionFromSingleEndSourceStaysSingleEnd() async throws {
        let resultDir = try makeResultFolder()
        let sidecar = resultDir.appendingPathComponent("classification-result.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        config["interleavedInput"] = false
        object["config"] = config
        try JSONSerialization.data(withJSONObject: object).write(to: sidecar)

        let (bundleURL, _) = try await extractSimplexvirusBundle(from: resultDir)
        let persisted = try XCTUnwrap(FASTQMetadataStore.load(for: try payload(in: bundleURL)))
        XCTAssertEqual(persisted.ingestion?.pairingMode, .singleEnd,
                       "without a paired source record the output is not claimed as pairs")
        XCTAssertEqual(try extractionParameters(in: bundleURL)["classifierExtractionOutputPairingMode"], "single_end")
    }

    func testPairingDecisionHelpers() throws {
        let dir = projectRoot.appendingPathComponent("helpers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let unpaired = dir.appendingPathComponent("unpaired.fastq")
        try "@a/1\nACGT\n+\nIIII\n@b/1\nACGT\n+\nIIII\n".write(to: unpaired, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClassifierReadResolver.extractedPairingMode(ofInterleavedSourceOutput: unpaired), .singleEnd,
                       "a selection that kept no adjacent mates is single-end")

        let paired = dir.appendingPathComponent("paired.fastq")
        try "@a/1\nACGT\n+\nIIII\n@a/2\nACGT\n+\nIIII\n".write(to: paired, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClassifierReadResolver.extractedPairingMode(ofInterleavedSourceOutput: paired), .interleaved)

        var config = try ClassificationResult.load(from: try makeResultFolder()).config
        XCTAssertTrue(ClassifierReadResolver.sourceHoldsInterleavedPairs(config: config, sourceFASTQs: [paired]))
        XCTAssertFalse(
            ClassifierReadResolver.sourceHoldsInterleavedPairs(config: config, sourceFASTQs: [paired, unpaired]),
            "split R1/R2 sources are concatenated mate-blocked, not interleaved"
        )
        config.interleavedInput = false
        XCTAssertFalse(ClassifierReadResolver.sourceHoldsInterleavedPairs(config: config, sourceFASTQs: [paired]))
    }
}
