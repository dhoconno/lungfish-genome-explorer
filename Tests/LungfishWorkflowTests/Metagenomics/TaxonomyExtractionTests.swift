// TaxonomyExtractionTests.swift - Tests for taxonomy-based read extraction
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

// MARK: - Progress Accumulator

/// A thread-safe accumulator for progress callback values in tests.
private actor ProgressAccumulator {
    var calls: [(Double, String)] = []

    func append(_ value: Double, _ message: String) {
        calls.append((value, message))
    }

    func getCalls() -> [(Double, String)] {
        calls
    }
}

// MARK: - FASTQ Content Reader

/// Reads FASTQ content from a file, decompressing if the file is gzipped.
///
/// `ReadExtractionService` produces `.fastq.gz` output via seqkit grep.
/// Tests that previously read plain `.fastq` files now use this helper.
private func readFASTQContent(_ url: URL) throws -> String {
    if url.pathExtension.lowercased() == "gz" {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzcat")
        process.arguments = [url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } else {
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - TaxonomyExtractionConfigTests

/// Tests for ``TaxonomyExtractionConfig`` construction and properties.
final class TaxonomyExtractionConfigTests: XCTestCase {

    // MARK: - Test Fixtures

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("extraction-test-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - testExtractionConfigCreation

    /// Verifies that TaxonomyExtractionConfig stores all properties correctly.
    func testExtractionConfigCreation() {
        let sourceURL = tempDir.appendingPathComponent("input.fastq")
        let outputURL = tempDir.appendingPathComponent("output.fastq")
        let classURL = tempDir.appendingPathComponent("classification.kraken")

        let config = TaxonomyExtractionConfig(
            taxIds: [562, 9606],
            includeChildren: true,
            sourceFile: sourceURL,
            outputFile: outputURL,
            classificationOutput: classURL
        )

        XCTAssertEqual(config.taxIds, [562, 9606])
        XCTAssertTrue(config.includeChildren)
        XCTAssertEqual(config.sourceFile, sourceURL)
        XCTAssertEqual(config.outputFile, outputURL)
        XCTAssertEqual(config.classificationOutput, classURL)
    }

    /// Verifies that the summary property generates a readable description.
    func testExtractionConfigSummary() {
        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: true,
            sourceFile: tempDir.appendingPathComponent("sample.fastq"),
            outputFile: tempDir.appendingPathComponent("extracted.fastq"),
            classificationOutput: tempDir.appendingPathComponent("output.kraken")
        )

        XCTAssertTrue(config.summary.contains("taxId 562"))
        XCTAssertTrue(config.summary.contains("with children"))
        XCTAssertTrue(config.summary.contains("sample.fastq"))
    }

    /// Verifies that the summary uses plural for multiple taxa.
    func testExtractionConfigSummaryMultipleTaxa() {
        let config = TaxonomyExtractionConfig(
            taxIds: [562, 9606, 1280],
            includeChildren: false,
            sourceFile: tempDir.appendingPathComponent("input.fastq"),
            outputFile: tempDir.appendingPathComponent("output.fastq"),
            classificationOutput: tempDir.appendingPathComponent("class.kraken")
        )

        XCTAssertTrue(config.summary.contains("3 taxa"))
        XCTAssertFalse(config.summary.contains("with children"))
    }

    /// Verifies that TaxonomyExtractionConfig conforms to Equatable.
    func testExtractionConfigEquatable() {
        let sourceURL = tempDir.appendingPathComponent("input.fastq")
        let outputURL = tempDir.appendingPathComponent("output.fastq")
        let classURL = tempDir.appendingPathComponent("class.kraken")

        let config1 = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: true,
            sourceFile: sourceURL,
            outputFile: outputURL,
            classificationOutput: classURL
        )
        let config2 = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: true,
            sourceFile: sourceURL,
            outputFile: outputURL,
            classificationOutput: classURL
        )

        XCTAssertEqual(config1, config2)
    }
}

// MARK: - TaxonomyExtractionPipelineTests

/// Tests for ``TaxonomyExtractionPipeline`` descendant collection and read extraction.
final class TaxonomyExtractionPipelineTests: XCTestCase {

    // MARK: - Test Fixtures

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("extraction-pipeline-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Creates a simple taxonomy tree for testing.
    ///
    /// ```
    /// root (1) -- 1000 reads
    ///   +-- Bacteria (2) -- 800 reads
    ///   |     +-- Proteobacteria (1224) -- 500 reads
    ///   |     |     +-- Gammaproteobacteria (1236) -- 400 reads
    ///   |     |           +-- Escherichia (561) -- 300 reads
    ///   |     |                 +-- E. coli (562) -- 200 reads
    ///   |     +-- Firmicutes (1239) -- 300 reads
    ///   |           +-- Staphylococcus (1279) -- 150 reads
    ///   |                 +-- S. aureus (1280) -- 100 reads
    ///   +-- Archaea (2157) -- 200 reads
    /// ```
    private func makeTestTree() -> TaxonTree {
        let root = TaxonNode(taxId: 1, name: "root", rank: .root, depth: 0,
                             readsDirect: 0, readsClade: 1000,
                             fractionClade: 1.0, fractionDirect: 0.0, parentTaxId: nil)

        let bacteria = TaxonNode(taxId: 2, name: "Bacteria", rank: .domain, depth: 1,
                                 readsDirect: 0, readsClade: 800,
                                 fractionClade: 0.8, fractionDirect: 0.0, parentTaxId: 1)

        let proteo = TaxonNode(taxId: 1224, name: "Proteobacteria", rank: .phylum, depth: 2,
                               readsDirect: 0, readsClade: 500,
                               fractionClade: 0.5, fractionDirect: 0.0, parentTaxId: 2)

        let gamma = TaxonNode(taxId: 1236, name: "Gammaproteobacteria", rank: .class, depth: 3,
                              readsDirect: 100, readsClade: 400,
                              fractionClade: 0.4, fractionDirect: 0.1, parentTaxId: 1224)

        let escherichia = TaxonNode(taxId: 561, name: "Escherichia", rank: .genus, depth: 4,
                                    readsDirect: 100, readsClade: 300,
                                    fractionClade: 0.3, fractionDirect: 0.1, parentTaxId: 1236)

        let ecoli = TaxonNode(taxId: 562, name: "Escherichia coli", rank: .species, depth: 5,
                              readsDirect: 200, readsClade: 200,
                              fractionClade: 0.2, fractionDirect: 0.2, parentTaxId: 561)

        let firmicutes = TaxonNode(taxId: 1239, name: "Firmicutes", rank: .phylum, depth: 2,
                                   readsDirect: 150, readsClade: 300,
                                   fractionClade: 0.3, fractionDirect: 0.15, parentTaxId: 2)

        let staph = TaxonNode(taxId: 1279, name: "Staphylococcus", rank: .genus, depth: 3,
                              readsDirect: 50, readsClade: 150,
                              fractionClade: 0.15, fractionDirect: 0.05, parentTaxId: 1239)

        let saureus = TaxonNode(taxId: 1280, name: "Staphylococcus aureus", rank: .species, depth: 4,
                                readsDirect: 100, readsClade: 100,
                                fractionClade: 0.1, fractionDirect: 0.1, parentTaxId: 1279)

        let archaea = TaxonNode(taxId: 2157, name: "Archaea", rank: .domain, depth: 1,
                                readsDirect: 200, readsClade: 200,
                                fractionClade: 0.2, fractionDirect: 0.2, parentTaxId: 1)

        // Wire up parent-child relationships
        root.children = [bacteria, archaea]
        bacteria.parent = root
        archaea.parent = root

        bacteria.children = [proteo, firmicutes]
        proteo.parent = bacteria
        firmicutes.parent = bacteria

        proteo.children = [gamma]
        gamma.parent = proteo

        gamma.children = [escherichia]
        escherichia.parent = gamma

        escherichia.children = [ecoli]
        ecoli.parent = escherichia

        firmicutes.children = [staph]
        staph.parent = firmicutes

        staph.children = [saureus]
        saureus.parent = staph

        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: 1000)
    }

    /// Creates a mock Kraken2 per-read classification output file.
    private func makeClassificationOutput(reads: [(readId: String, taxId: Int, classified: Bool)]) throws -> URL {
        let url = tempDir.appendingPathComponent("classification.kraken")
        var lines: [String] = []
        for read in reads {
            let status = read.classified ? "C" : "U"
            lines.append("\(status)\t\(read.readId)\t\(read.taxId)\t150\t0:150")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a mock Kraken2 per-read classification output file at a specified path.
    private func makeClassificationOutput(
        reads: [(readId: String, taxId: Int, classified: Bool)],
        at url: URL
    ) throws -> URL {
        var lines: [String] = []
        for read in reads {
            let status = read.classified ? "C" : "U"
            lines.append("\(status)\t\(read.readId)\t\(read.taxId)\t150\t0:150")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a mock FASTQ file.
    private func makeFASTQ(reads: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent("input.fastq")
        var content = ""
        for readId in reads {
            content += "@\(readId)\n"
            content += "ATCGATCGATCGATCG\n"
            content += "+\n"
            content += "IIIIIIIIIIIIIIII\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a mock FASTQ file at a specified path.
    private func makeFASTQ(reads: [String], at url: URL) throws -> URL {
        var content = ""
        for readId in reads {
            content += "@\(readId)\n"
            content += "ATCGATCGATCGATCG\n"
            content += "+\n"
            content += "IIIIIIIIIIIIIIII\n"
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - testCollectDescendantTaxIds

    /// Verifies that descendant tax ID collection includes all children.
    func testCollectDescendantTaxIds() async {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        // Collect descendants of Proteobacteria (1224)
        let descendants = await pipeline.collectDescendantTaxIds([1224], tree: tree)

        // Should include 1224, 1236, 561, 562
        XCTAssertTrue(descendants.contains(1224), "Should include the root taxId")
        XCTAssertTrue(descendants.contains(1236), "Should include Gammaproteobacteria")
        XCTAssertTrue(descendants.contains(561), "Should include Escherichia")
        XCTAssertTrue(descendants.contains(562), "Should include E. coli")
        XCTAssertFalse(descendants.contains(1239), "Should not include Firmicutes")
        XCTAssertFalse(descendants.contains(2157), "Should not include Archaea")
        XCTAssertEqual(descendants.count, 4)
    }

    /// Verifies that descendant collection for a leaf node returns just that node.
    func testCollectDescendantTaxIdsLeafNode() async {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let descendants = await pipeline.collectDescendantTaxIds([562], tree: tree)

        XCTAssertEqual(descendants, [562])
    }

    /// Verifies that unknown tax IDs in the input set are preserved.
    func testCollectDescendantTaxIdsUnknownTaxId() async {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let descendants = await pipeline.collectDescendantTaxIds([99999], tree: tree)

        // Unknown taxId is kept in the set (it won't match any node)
        XCTAssertEqual(descendants, [99999])
    }

    // MARK: - testExtractReadsFromClassification

    /// Verifies end-to-end extraction of reads matching a single species.
    func testExtractReadsFromClassification() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        // Create classification output with some reads classified to E. coli (562)
        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
            (readId: "read2", taxId: 1280, classified: true),
            (readId: "read3", taxId: 562, classified: true),
            (readId: "read4", taxId: 0, classified: false),
            (readId: "read5", taxId: 561, classified: true),
        ])

        // Create FASTQ with all reads
        let fastqURL = try makeFASTQ(reads: ["read1", "read2", "read3", "read4", "read5"])

        let outputURL = tempDir.appendingPathComponent("extracted.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        let result = try await pipeline.extract(config: config, tree: tree).first!

        // Output is now .fastq.gz (ReadExtractionService uses seqkit grep which produces gzipped output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let content = try readFASTQContent(result)
        XCTAssertTrue(content.contains("@read1"), "Should contain read1")
        XCTAssertTrue(content.contains("@read3"), "Should contain read3")
        XCTAssertFalse(content.contains("@read2"), "Should not contain read2 (S. aureus)")
        XCTAssertFalse(content.contains("@read4"), "Should not contain read4 (unclassified)")
        XCTAssertFalse(content.contains("@read5"), "Should not contain read5 (Escherichia)")
    }

    // MARK: - testExtractWithChildrenIncluded

    /// Verifies that extraction with includeChildren collects clade reads.
    func testExtractWithChildrenIncluded() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),   // E. coli (child of 561)
            (readId: "read2", taxId: 1280, classified: true),  // S. aureus (not in clade)
            (readId: "read3", taxId: 561, classified: true),   // Escherichia (target)
            (readId: "read4", taxId: 1236, classified: true),  // Gammaproteobacteria (not descendant of 561)
        ])

        let fastqURL = try makeFASTQ(reads: ["read1", "read2", "read3", "read4"])
        let outputURL = tempDir.appendingPathComponent("clade_extracted.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [561],    // Escherichia genus
            includeChildren: true,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        let result = try await pipeline.extract(config: config, tree: tree).first!

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let content = try readFASTQContent(result)
        XCTAssertTrue(content.contains("@read1"), "Should contain read1 (E. coli, child of 561)")
        XCTAssertTrue(content.contains("@read3"), "Should contain read3 (Escherichia, direct)")
        XCTAssertFalse(content.contains("@read2"), "Should not contain read2 (S. aureus)")
        XCTAssertFalse(content.contains("@read4"), "Should not contain read4 (Gammaproteobacteria)")
    }

    // MARK: - testExtractWithChildrenExcluded

    /// Verifies that extraction without children only gets direct assignments.
    func testExtractWithChildrenExcluded() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),   // E. coli (child of 561)
            (readId: "read2", taxId: 561, classified: true),   // Escherichia (direct)
        ])

        let fastqURL = try makeFASTQ(reads: ["read1", "read2"])
        let outputURL = tempDir.appendingPathComponent("direct_extracted.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [561],    // Escherichia genus, NOT including children
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        let result = try await pipeline.extract(config: config, tree: tree).first!

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        let content = try readFASTQContent(result)
        XCTAssertTrue(content.contains("@read2"), "Should contain read2 (Escherichia, direct)")
        XCTAssertFalse(content.contains("@read1"), "Should not contain read1 (E. coli, child)")
    }

    // MARK: - testEmptyExtractionResult

    /// Verifies that extraction throws when no reads match the criteria.
    func testEmptyExtractionResult() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
            (readId: "read2", taxId: 1280, classified: true),
        ])

        let fastqURL = try makeFASTQ(reads: ["read1", "read2"])
        let outputURL = tempDir.appendingPathComponent("empty_extracted.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [99999],  // Non-existent taxId
            includeChildren: true,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        do {
            _ = try await pipeline.extract(config: config, tree: tree)
            XCTFail("Expected TaxonomyExtractionError.noMatchingReads")
        } catch let error as TaxonomyExtractionError {
            if case .noMatchingReads = error {
                // Expected
            } else {
                XCTFail("Expected noMatchingReads, got \(error)")
            }
        }
    }

    // MARK: - testClassificationOutputNotFound

    /// Verifies that extraction throws when the classification file is missing.
    func testClassificationOutputNotFound() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let fastqURL = try makeFASTQ(reads: ["read1"])
        let outputURL = tempDir.appendingPathComponent("output.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: tempDir.appendingPathComponent("nonexistent.kraken")
        )

        do {
            _ = try await pipeline.extract(config: config, tree: tree)
            XCTFail("Expected TaxonomyExtractionError.classificationOutputNotFound")
        } catch let error as TaxonomyExtractionError {
            if case .classificationOutputNotFound = error {
                // Expected
            } else {
                XCTFail("Expected classificationOutputNotFound, got \(error)")
            }
        }
    }

    // MARK: - testSourceFileNotFound

    /// Verifies that extraction throws when the source FASTQ is missing.
    func testSourceFileNotFound() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
        ])
        let outputURL = tempDir.appendingPathComponent("output.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: tempDir.appendingPathComponent("nonexistent.fastq"),
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        do {
            _ = try await pipeline.extract(config: config, tree: tree)
            XCTFail("Expected TaxonomyExtractionError.sourceFileNotFound")
        } catch let error as TaxonomyExtractionError {
            if case .sourceFileNotFound = error {
                // Expected
            } else {
                XCTFail("Expected sourceFileNotFound, got \(error)")
            }
        }
    }

    // MARK: - testProgressCallback

    /// Verifies that the progress callback is called during extraction.
    func testProgressCallback() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
        ])
        let fastqURL = try makeFASTQ(reads: ["read1"])
        let outputURL = tempDir.appendingPathComponent("progress_test.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        let accumulator = ProgressAccumulator()
        _ = try await pipeline.extract(config: config, tree: tree, progress: { pct, msg in
            Task { await accumulator.append(pct, msg) }
        })

        // Give the async tasks a moment to complete
        try await Task.sleep(for: .milliseconds(100))

        let progressCalls = await accumulator.getCalls()
        XCTAssertFalse(progressCalls.isEmpty, "Progress callback should have been called")

        // Check that progress starts near 0 and ends at 1
        if let first = progressCalls.first {
            XCTAssertLessThanOrEqual(first.0, 0.1)
        }
        if let last = progressCalls.last {
            XCTAssertEqual(last.0, 1.0, accuracy: 0.01)
        }
    }

    // MARK: - testReadIdWithDescription

    /// Verifies that read IDs with description fields are correctly matched.
    ///
    /// FASTQ headers can have descriptions after the read ID separated by whitespace:
    /// `@read1 length=150 comment`
    func testReadIdWithDescription() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
        ])

        // FASTQ with description in header
        let fastqURL = tempDir.appendingPathComponent("described.fastq")
        let content = "@read1 length=150 runid=abc123\nATCGATCGATCGATCG\n+\nIIIIIIIIIIIIIIII\n@read2 length=150\nATCGATCGATCGATCG\n+\nIIIIIIIIIIIIIIII\n"
        try content.write(to: fastqURL, atomically: true, encoding: .utf8)

        let outputURL = tempDir.appendingPathComponent("described_out.fastq")

        // keepReadPairs: false — seqkit grep matches by sequence ID (before first
        // space) which correctly handles description fields. The -n flag (used for
        // pair matching) causes full-name matching which would break this test.
        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput,
            keepReadPairs: false
        )

        let results = try await pipeline.extract(config: config, tree: tree)
        let resultURL = results.first!

        let output = try readFASTQContent(resultURL)
        XCTAssertTrue(output.contains("@read1"), "Should match read1 despite description")
        XCTAssertFalse(output.contains("@read2"), "Should not match read2")
    }

    // MARK: - testExtractionPipelineWithSimulatedData

    /// Verifies end-to-end extraction with a realistic simulated dataset.
    ///
    /// Creates a 50-read FASTQ file with reads classified across multiple taxa,
    /// runs the extraction pipeline targeting E. coli (taxId 562) with children
    /// included, and verifies that only the expected reads appear in the output
    /// and that progress was reported.
    func testExtractionPipelineWithSimulatedData() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        // Build a larger simulated dataset with 50 reads spread across taxa
        var classReads: [(readId: String, taxId: Int, classified: Bool)] = []
        var fastqReadIDs: [String] = []

        // 10 reads classified to E. coli (562)
        for i in 0..<10 {
            let readId = "ecoli_read_\(i)"
            classReads.append((readId: readId, taxId: 562, classified: true))
            fastqReadIDs.append(readId)
        }
        // 5 reads classified to Escherichia (561) -- parent of E. coli
        for i in 0..<5 {
            let readId = "escherichia_read_\(i)"
            classReads.append((readId: readId, taxId: 561, classified: true))
            fastqReadIDs.append(readId)
        }
        // 8 reads classified to S. aureus (1280) -- different clade
        for i in 0..<8 {
            let readId = "saureus_read_\(i)"
            classReads.append((readId: readId, taxId: 1280, classified: true))
            fastqReadIDs.append(readId)
        }
        // 12 reads classified to Archaea (2157)
        for i in 0..<12 {
            let readId = "archaea_read_\(i)"
            classReads.append((readId: readId, taxId: 2157, classified: true))
            fastqReadIDs.append(readId)
        }
        // 15 unclassified reads
        for i in 0..<15 {
            let readId = "unclassified_read_\(i)"
            classReads.append((readId: readId, taxId: 0, classified: false))
            fastqReadIDs.append(readId)
        }

        let classURL = tempDir.appendingPathComponent("simulated.kraken")
        _ = try makeClassificationOutput(reads: classReads, at: classURL)

        let fastqURL = tempDir.appendingPathComponent("simulated.fastq")
        _ = try makeFASTQ(reads: fastqReadIDs, at: fastqURL)

        let outputURL = tempDir.appendingPathComponent("simulated_extracted.fastq")

        // Extract Escherichia genus (561) with children -- should get both
        // Escherichia (561) and E. coli (562) reads.
        let config = TaxonomyExtractionConfig(
            taxIds: [561],
            includeChildren: true,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classURL
        )

        let accumulator = ProgressAccumulator()
        let resultURLs = try await pipeline.extract(config: config, tree: tree, progress: { pct, msg in
            Task { await accumulator.append(pct, msg) }
        })

        // Verify output file was created (now .fastq.gz via ReadExtractionService)
        let resultURL = resultURLs.first!
        XCTAssertTrue(FileManager.default.fileExists(atPath: resultURL.path))

        // Read and verify output content (decompressing if gzipped)
        let output = try readFASTQContent(resultURL)

        // Should contain all 10 E. coli reads
        for i in 0..<10 {
            XCTAssertTrue(output.contains("@ecoli_read_\(i)"),
                          "Should contain ecoli_read_\(i)")
        }

        // Should contain all 5 Escherichia reads
        for i in 0..<5 {
            XCTAssertTrue(output.contains("@escherichia_read_\(i)"),
                          "Should contain escherichia_read_\(i)")
        }

        // Should NOT contain S. aureus reads
        for i in 0..<8 {
            XCTAssertFalse(output.contains("@saureus_read_\(i)"),
                           "Should not contain saureus_read_\(i)")
        }

        // Should NOT contain Archaea reads
        for i in 0..<12 {
            XCTAssertFalse(output.contains("@archaea_read_\(i)"),
                           "Should not contain archaea_read_\(i)")
        }

        // Should NOT contain unclassified reads
        for i in 0..<15 {
            XCTAssertFalse(output.contains("@unclassified_read_\(i)"),
                           "Should not contain unclassified_read_\(i)")
        }

        // Verify each extracted record is a valid 4-line FASTQ record
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        // 15 reads * 4 lines each = 60 lines
        XCTAssertEqual(lines.count, 60, "Expected 60 lines (15 reads * 4 lines each)")

        // Verify progress was reported
        try await Task.sleep(for: .milliseconds(100))
        let progressCalls = await accumulator.getCalls()
        XCTAssertFalse(progressCalls.isEmpty, "Progress should have been reported")

        // Final progress should be at 1.0
        if let lastProgress = progressCalls.last {
            XCTAssertEqual(lastProgress.0, 1.0, accuracy: 0.01,
                           "Final progress should be 1.0")
        }
    }

    // MARK: - testExtractedBundleCreation

    /// Verifies that a `.lungfishfastq` bundle can be correctly created from
    /// an extraction output FASTQ file.
    ///
    /// This test simulates what ``ViewerViewController/createExtractedFASTQBundle``
    /// does: runs the extraction pipeline, then creates a bundle directory with
    /// the FASTQ file inside, plus a metadata sidecar and provenance JSON.
    func testExtractedBundleCreation() async throws {
        let fm = FileManager.default
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        // Create simulated input files
        let classURL = tempDir.appendingPathComponent("bundle_test.kraken")
        _ = try makeClassificationOutput(reads: [
            (readId: "r1", taxId: 562, classified: true),
            (readId: "r2", taxId: 562, classified: true),
            (readId: "r3", taxId: 1280, classified: true),
        ], at: classURL)

        let fastqURL = tempDir.appendingPathComponent("bundle_test.fastq")
        _ = try makeFASTQ(reads: ["r1", "r2", "r3"], at: fastqURL)

        let outputURL = tempDir.appendingPathComponent("bundle_test_Escherichia_coli.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classURL
        )

        // Run extraction
        let extractedURL = try await pipeline.extract(config: config, tree: tree).first!
        XCTAssertTrue(fm.fileExists(atPath: extractedURL.path))

        // Simulate bundle creation (mirrors ViewerViewController.createExtractedFASTQBundle)
        let baseName = FASTQBundle.deriveBaseName(from: extractedURL)
        let bundleName = "\(baseName).\(FASTQBundle.directoryExtension)"
        let parentDir = extractedURL.deletingLastPathComponent()
        let bundleURL = parentDir.appendingPathComponent(bundleName)

        // Create bundle directory
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // Move extracted FASTQ into bundle
        let destFASTQ = bundleURL.appendingPathComponent(extractedURL.lastPathComponent)
        try fm.moveItem(at: extractedURL, to: destFASTQ)

        // Write metadata sidecar
        var metadata = PersistedFASTQMetadata()
        metadata.downloadSource = "taxonomy-extraction"
        metadata.downloadDate = Date()
        FASTQMetadataStore.save(metadata, for: destFASTQ)

        // Write extraction provenance
        let provenance: [String: Any] = [
            "extractionType": "taxonomy",
            "taxIds": config.taxIds.sorted(),
            "includeChildren": config.includeChildren,
            "sourceFile": config.sourceFile.lastPathComponent,
            "classificationOutput": config.classificationOutput.lastPathComponent,
            "extractedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let provenanceURL = bundleURL.appendingPathComponent("extraction-provenance.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: provenance,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try data.write(to: provenanceURL, options: .atomic)
        }

        // Verify bundle structure
        XCTAssertTrue(FASTQBundle.isBundleURL(bundleURL),
                      "Should be recognized as a .lungfishfastq bundle")

        // Verify the FASTQ file is inside the bundle
        XCTAssertTrue(fm.fileExists(atPath: destFASTQ.path),
                      "Extracted FASTQ should exist inside the bundle")

        // Verify the original extraction output was moved (no longer at original location)
        XCTAssertFalse(fm.fileExists(atPath: extractedURL.path),
                       "Original extracted FASTQ should have been moved into the bundle")

        // Verify the primary FASTQ can be resolved
        let resolvedPrimary = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL)
        XCTAssertNotNil(resolvedPrimary, "Should resolve a primary FASTQ from the bundle")
        XCTAssertEqual(resolvedPrimary?.lastPathComponent, extractedURL.lastPathComponent)

        // Verify the FASTQ content is correct (should contain r1 and r2 but not r3)
        let content = try readFASTQContent(destFASTQ)
        XCTAssertTrue(content.contains("@r1"), "Bundle FASTQ should contain r1")
        XCTAssertTrue(content.contains("@r2"), "Bundle FASTQ should contain r2")
        XCTAssertFalse(content.contains("@r3"), "Bundle FASTQ should not contain r3 (S. aureus)")

        // Verify metadata sidecar was written
        let loadedMetadata = FASTQMetadataStore.load(for: destFASTQ)
        XCTAssertNotNil(loadedMetadata, "Metadata sidecar should be loadable")
        XCTAssertEqual(loadedMetadata?.downloadSource, "taxonomy-extraction")
        XCTAssertNotNil(loadedMetadata?.downloadDate)

        // Verify provenance JSON was written and is valid
        XCTAssertTrue(fm.fileExists(atPath: provenanceURL.path),
                      "Provenance JSON should exist")
        let provenanceData = try Data(contentsOf: provenanceURL)
        let parsed = try JSONSerialization.jsonObject(with: provenanceData) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["extractionType"] as? String, "taxonomy")
        XCTAssertEqual(parsed?["includeChildren"] as? Bool, false)
        XCTAssertEqual(parsed?["sourceFile"] as? String, "bundle_test.fastq")

        let parsedTaxIds = parsed?["taxIds"] as? [Int]
        XCTAssertNotNil(parsedTaxIds)
        XCTAssertEqual(parsedTaxIds, [562])
    }
}

// MARK: - Paired-End Extraction Tests (Phase G5)

extension TaxonomyExtractionPipelineTests {

    /// Verifies that paired-end extraction filters both R1 and R2 files using the same read ID set.
    func testPairedEndExtraction() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        // Create classification output with reads from both mates
        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),   // E. coli
            (readId: "read2", taxId: 1280, classified: true),  // S. aureus
            (readId: "read3", taxId: 562, classified: true),   // E. coli
        ])

        // Create paired FASTQ files (R1 and R2)
        let r1URL = tempDir.appendingPathComponent("sample_R1.fastq")
        let r2URL = tempDir.appendingPathComponent("sample_R2.fastq")
        _ = try makeFASTQ(reads: ["read1", "read2", "read3"], at: r1URL)
        _ = try makeFASTQ(reads: ["read1", "read2", "read3"], at: r2URL)

        let outputR1 = tempDir.appendingPathComponent("extracted_R1.fastq")
        let outputR2 = tempDir.appendingPathComponent("extracted_R2.fastq")

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFiles: [r1URL, r2URL],
            outputFiles: [outputR1, outputR2],
            classificationOutput: classOutput
        )

        let results = try await pipeline.extract(config: config, tree: tree)

        // Should produce two output files (now .fastq.gz via ReadExtractionService)
        XCTAssertEqual(results.count, 2, "Should produce two output files for paired-end")
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[1].path))

        // Both files should contain read1 and read3 (E. coli) but not read2 (S. aureus)
        let r1Content = try readFASTQContent(results[0])
        XCTAssertTrue(r1Content.contains("@read1"), "R1 should contain read1")
        XCTAssertTrue(r1Content.contains("@read3"), "R1 should contain read3")
        XCTAssertFalse(r1Content.contains("@read2"), "R1 should not contain read2")

        let r2Content = try readFASTQContent(results[1])
        XCTAssertTrue(r2Content.contains("@read1"), "R2 should contain read1")
        XCTAssertTrue(r2Content.contains("@read3"), "R2 should contain read3")
        XCTAssertFalse(r2Content.contains("@read2"), "R2 should not contain read2")
    }

    /// Verifies that single-file configs still work with the backward-compatible initializer.
    func testSingleFileBackwardsCompat() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
            (readId: "read2", taxId: 1280, classified: true),
        ])

        let fastqURL = try makeFASTQ(reads: ["read1", "read2"])
        let outputURL = tempDir.appendingPathComponent("compat_extracted.fastq")

        // Use the single-file initializer
        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFile: fastqURL,
            outputFile: outputURL,
            classificationOutput: classOutput
        )

        // Verify backward-compatible properties
        XCTAssertEqual(config.sourceFile, fastqURL)
        XCTAssertEqual(config.outputFile, outputURL)
        XCTAssertEqual(config.sourceFiles.count, 1)
        XCTAssertEqual(config.outputFiles.count, 1)
        XCTAssertFalse(config.isPairedEnd)

        let results = try await pipeline.extract(config: config, tree: tree)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: results[0].path))

        let content = try readFASTQContent(results[0])
        XCTAssertTrue(content.contains("@read1"))
        XCTAssertFalse(content.contains("@read2"))
    }

    /// Verifies that mismatched source/output counts produce an error.
    func testSourceOutputCountMismatch() async throws {
        let tree = makeTestTree()
        let pipeline = TaxonomyExtractionPipeline()

        let classOutput = try makeClassificationOutput(reads: [
            (readId: "read1", taxId: 562, classified: true),
        ])

        let fastqURL = try makeFASTQ(reads: ["read1"])

        let config = TaxonomyExtractionConfig(
            taxIds: [562],
            includeChildren: false,
            sourceFiles: [fastqURL],
            outputFiles: [
                tempDir.appendingPathComponent("out1.fastq"),
                tempDir.appendingPathComponent("out2.fastq"),
            ],
            classificationOutput: classOutput
        )

        do {
            _ = try await pipeline.extract(config: config, tree: tree)
            XCTFail("Expected sourceOutputCountMismatch error")
        } catch let error as TaxonomyExtractionError {
            if case .sourceOutputCountMismatch(let sources, let outputs) = error {
                XCTAssertEqual(sources, 1)
                XCTAssertEqual(outputs, 2)
            } else {
                XCTFail("Expected sourceOutputCountMismatch, got \(error)")
            }
        }
    }
}

// MARK: - Classification Result Persistence Tests (Phase G7)

final class ClassificationResultPersistenceTests: XCTestCase {

    private let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("classification-persist-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Creates a minimal kreport file for testing.
    private func makeMinimalKreport() throws -> URL {
        let url = tempDir.appendingPathComponent("classification.kreport")
        let content = """
        100.00\t1000\t0\tR\t1\troot
         80.00\t800\t0\tD\t2\t  Bacteria
         50.00\t500\t200\tG\t561\t    Escherichia
         20.00\t200\t200\tS\t562\t      Escherichia coli
         20.00\t200\t200\tD\t2157\t  Archaea
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a mock kraken output file.
    private func makeKrakenOutput() throws -> URL {
        let url = tempDir.appendingPathComponent("classification.kraken")
        try "C\tread1\t562\t150\t0:150\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Verifies that save/load round-trips preserve all metadata.
    func testSaveLoadRoundTrip() async throws {
        let kreportURL = try makeMinimalKreport()
        let krakenURL = try makeKrakenOutput()

        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: tempDir,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 4,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: tempDir
        )

        let tree = try KreportParser.parse(url: kreportURL)
        let provenanceId = UUID()

        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: kreportURL,
            outputURL: krakenURL,
            brackenURL: nil,
            runtime: 42.5,
            toolVersion: "2.1.3",
            provenanceId: provenanceId
        )

        // Save
        try result.save(to: tempDir)

        // Verify file exists
        XCTAssertTrue(ClassificationResult.exists(in: tempDir))

        // Load
        let loaded = try ClassificationResult.load(from: tempDir)

        // Verify metadata
        XCTAssertEqual(loaded.config.databaseName, "Viral")
        XCTAssertEqual(loaded.config.confidence, 0.2)
        XCTAssertEqual(loaded.runtime, 42.5)
        XCTAssertEqual(loaded.toolVersion, "2.1.3")
        XCTAssertEqual(loaded.provenanceId, provenanceId)
        XCTAssertNil(loaded.brackenURL)

        // Verify the tree was rebuilt from the kreport
        XCTAssertEqual(loaded.tree.totalReads, tree.totalReads)
        XCTAssertEqual(loaded.tree.speciesCount, tree.speciesCount)
    }

    /// Verifies that loading from a kreport correctly rebuilds the tree.
    func testLoadFromKreport() async throws {
        let kreportURL = try makeMinimalKreport()
        let krakenURL = try makeKrakenOutput()

        let config = ClassificationConfig(
            inputFiles: [tempDir.appendingPathComponent("reads.fastq")],
            isPairedEnd: false,
            databaseName: "Test",
            databasePath: tempDir,
            outputDirectory: tempDir
        )

        let tree = try KreportParser.parse(url: kreportURL)

        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: kreportURL,
            outputURL: krakenURL,
            brackenURL: nil,
            runtime: 10.0,
            toolVersion: "2.1.3",
            provenanceId: nil
        )

        try result.save(to: tempDir)

        let loaded = try ClassificationResult.load(from: tempDir)

        // Tree should have the species node for E. coli
        let ecoli = loaded.tree.node(taxId: 562)
        XCTAssertNotNil(ecoli, "Should have E. coli node")
        XCTAssertEqual(ecoli?.name, "Escherichia coli")
    }

    /// Verifies that loading fails gracefully when sidecar is missing.
    func testLoadMissingSidecar() {
        let emptyDir = tempDir.appendingPathComponent("empty")
        try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)

        XCTAssertFalse(ClassificationResult.exists(in: emptyDir))

        do {
            _ = try ClassificationResult.load(from: emptyDir)
            XCTFail("Expected sidecarNotFound error")
        } catch let error as ClassificationResultLoadError {
            if case .sidecarNotFound = error {
                // Expected
            } else {
                XCTFail("Expected sidecarNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
