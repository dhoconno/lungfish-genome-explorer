// FASTQReadLayoutClassifierTests.swift - Interleaved / mixed / single-end FASTQ detection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class FASTQReadLayoutClassifierTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-read-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func fastq(_ headers: [String]) -> String {
        headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
    }

    // MARK: - Pairing rule

    func testSlashSuffixMates() {
        XCTAssertTrue(FASTQReadLayoutClassifier.areMates("r1/1", "r1/2"))
        XCTAssertTrue(FASTQReadLayoutClassifier.areMates("r1/1 extra", "r1/2 extra"))
        XCTAssertFalse(FASTQReadLayoutClassifier.areMates("r1/2", "r1/1"), "R2 before R1 is not a pair")
        XCTAssertFalse(FASTQReadLayoutClassifier.areMates("r1/1", "r2/2"))
    }

    func testIlluminaCommentMates() {
        XCTAssertTrue(FASTQReadLayoutClassifier.areMates(
            "M001:1:FC:1:1101:100:200 1:N:0:ACGT",
            "M001:1:FC:1:1101:100:200 2:N:0:ACGT"
        ))
        XCTAssertFalse(FASTQReadLayoutClassifier.areMates(
            "M001:1:FC:1:1101:100:200 1:N:0:ACGT",
            "M001:1:FC:1:1101:100:201 1:N:0:ACGT"
        ))
    }

    func testIdenticalUnmarkedNamesAreMates() {
        XCTAssertTrue(FASTQReadLayoutClassifier.areMates("SRR1.1", "SRR1.1"))
        XCTAssertFalse(FASTQReadLayoutClassifier.areMates("SRR1.1", "SRR1.2"))
    }

    // MARK: - Header classification

    func testStrictlyInterleavedSlashNames() {
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["a/1", "a/2", "b/1", "b/2"],
            scannedWholeFile: true
        )
        XCTAssertEqual(result.layout, .strictlyInterleaved)
        XCTAssertEqual(result.matePairs, 2)
        XCTAssertEqual(result.unpairedRecords, 0)
    }

    func testStrictlyInterleavedIlluminaNames() {
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["x:1 1:N:0:1", "x:1 2:N:0:1", "x:2 1:N:0:1", "x:2 2:N:0:1"],
            scannedWholeFile: true
        )
        XCTAssertEqual(result.layout, .strictlyInterleaved)
    }

    func testMixedPairsAndMergedSingletons() {
        // VSP2-style: merged reads (fastp appends a merged_ comment) between pairs.
        let result = FASTQReadLayoutClassifier.classify(
            headers: [
                "a 1:N:0:1", "a 2:N:0:1",
                "m 1:N:0:1 merged_150_20",
                "b 1:N:0:1", "b 2:N:0:1",
                "n 1:N:0:1 merged_140_30",
            ],
            scannedWholeFile: true
        )
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertEqual(result.matePairs, 2)
        XCTAssertEqual(result.unpairedRecords, 2)
    }

    func testTrueSingleEnd() {
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["a 1:N:0:1", "b 1:N:0:1", "c 1:N:0:1"],
            scannedWholeFile: true
        )
        XCTAssertEqual(result.layout, .singleEnd)
        XCTAssertEqual(result.matePairs, 0)
    }

    func testTrailingOrphanInWholeFileMakesItMixed() {
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["a/1", "a/2", "b/1"],
            scannedWholeFile: true
        )
        XCTAssertEqual(result.layout, .mixedInterleaved)
    }

    func testTruncatedScanEndingMidPairStaysStrict() {
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["a/1", "a/2", "b/1"],
            scannedWholeFile: false
        )
        XCTAssertEqual(result.layout, .strictlyInterleaved)
        XCTAssertEqual(result.unpairedRecords, 0)
    }

    func testMergeMetadataOverridesStrictLookingHead() {
        let hints = FASTQPairingMetadataHints(
            pairingMode: .interleaved,
            hasMergedOrUnpairedReads: true,
            mergeEvidence: "recipe VSP2 merges overlapping pairs"
        )
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["a/1", "a/2"],
            scannedWholeFile: false,
            metadata: hints
        )
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertTrue(result.reason.contains("merged"))
    }

    func testInterleavedMetadataWithMergedOnlyHeadIsMixed() {
        // Legacy VSP2 output concatenates merged reads before the pairs.
        let result = FASTQReadLayoutClassifier.classify(
            headers: ["m1", "m2", "m3"],
            scannedWholeFile: false,
            metadata: FASTQPairingMetadataHints(pairingMode: .interleaved)
        )
        XCTAssertEqual(result.layout, .mixedInterleaved)
    }

    // MARK: - Files and bundles

    func testClassifyPlainInterleavedFile() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("reads.fastq")
        try fastq(["a/1", "a/2", "b/1", "b/2"]).write(to: url, atomically: true, encoding: .utf8)

        let result = FASTQReadLayoutClassifier.classify(inputURL: url)
        XCTAssertEqual(result.layout, .strictlyInterleaved)
        XCTAssertEqual(result.scannedRecords, 4)
        XCTAssertTrue(result.scannedWholeFile)
    }

    func testClassifyGzipInterleavedFile() throws {
        let dir = try makeTempDir()
        let plain = dir.appendingPathComponent("reads.fastq")
        try fastq(["a 1:N:0:1", "a 2:N:0:1"]).write(to: plain, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = [plain.path]
        try process.run()
        process.waitUntilExit()
        let gz = dir.appendingPathComponent("reads.fastq.gz")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gz.path))

        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: gz).layout, .strictlyInterleaved)
    }

    func testScanStopsAtRecordLimit() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("reads.fastq")
        let headers = (0..<50).flatMap { ["r\($0)/1", "r\($0)/2"] }
        try fastq(headers).write(to: url, atomically: true, encoding: .utf8)

        let scan = try FASTQReadLayoutClassifier.readHeaders(from: url, limit: 10)
        XCTAssertEqual(scan.headers.count, 10)
        XCTAssertFalse(scan.scannedWholeFile)
    }

    func testBundleWithVSP2MergeRecipeIsMixedEvenWhenHeadAlternates() throws {
        let dir = try makeTempDir()
        let bundle = dir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastqURL = bundle.appendingPathComponent("reads.fastq")
        try fastq(["a/1", "a/2", "b/1", "b/2"]).write(to: fastqURL, atomically: true, encoding: .utf8)

        let recipe = RecipeAppliedInfo(
            recipeID: "illuminaVSP2TargetEnrichment",
            recipeName: "VSP2",
            stepResults: [RecipeStepResult(stepName: "PE merge (normal, min overlap: 12)", tool: "fastp", durationSeconds: 1)]
        )
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, recipeApplied: recipe)),
            for: fastqURL
        )

        let result = FASTQReadLayoutClassifier.classify(inputURL: bundle)
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertEqual(result.metadata.pairingMode, .interleaved)
        XCTAssertTrue(result.metadata.hasMergedOrUnpairedReads)
    }

    func testBundleWithInterleavedMetadataAndStrictContentIsStrict() throws {
        let dir = try makeTempDir()
        let bundle = dir.appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastqURL = bundle.appendingPathComponent("reads.fastq")
        try fastq(["a 1:N:0:1", "a 2:N:0:1"]).write(to: fastqURL, atomically: true, encoding: .utf8)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved)),
            for: fastqURL
        )

        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: bundle).layout, .strictlyInterleaved)
    }

    // MARK: - A file's own counts outrank the merge in its lineage (Phase 1.5 lane F6)

    /// The roles of a file that holds `pairs` pairs and no single read, as the
    /// FASTQ operations dialog's import records them.
    private func pairsOnlyRoles(naming filename: String, pairs: Int) -> ReadClassification {
        ReadClassification(files: [
            .init(filename: filename, role: .pairedR1, readCount: pairs),
            .init(filename: filename, role: .pairedR2, readCount: pairs),
        ])
    }

    /// A physical `full` derivative of reads `headers` whose lineage holds a
    /// paired-end merge, with `roles` and `recipe` in the sidecar of its file.
    private func makeMergeLineageChild(
        headers: [String],
        roles: ReadClassification?,
        recipe: RecipeAppliedInfo? = nil
    ) throws -> URL {
        let bundle = try makeTempDir().appendingPathComponent("child.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let fastqURL = bundle.appendingPathComponent("reads.fastq")
        try fastq(headers).write(to: fastqURL, atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .lengthFilter)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "child",
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: "reads.fastq",
                payload: .full(fastqFilename: "reads.fastq"),
                lineage: [FASTQDerivativeOperation(kind: .pairedEndMerge), operation],
                operation: operation,
                cachedStatistics: .placeholder(readCount: headers.count, baseCount: Int64(headers.count * 4)),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: bundle
        )
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(pairingMode: .singleEnd, recipeApplied: recipe),
                readClassification: roles
            ),
            for: fastqURL
        )
        return bundle
    }

    /// A merge in the lineage says single reads may be in the file, so mates
    /// beside it scan as mixed. An output of a merge bundle that kept only the
    /// unmerged pairs holds none, and its own sidecar counts say so, so the
    /// counts outrank the lineage and the file scans as pairs. The hints carry
    /// no merge evidence then.
    func testACountOfOnlyPairsOutranksTheMergeInTheLineage() throws {
        let headers = ["a/1", "a/2", "b/1", "b/2"]

        let uncounted = try makeMergeLineageChild(headers: headers, roles: nil)
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: uncounted).layout, .mixedInterleaved)

        let counted = try makeMergeLineageChild(headers: headers, roles: pairsOnlyRoles(naming: "reads.fastq", pairs: 2))
        let result = FASTQReadLayoutClassifier.classify(inputURL: counted)
        XCTAssertEqual(result.layout, .strictlyInterleaved)
        XCTAssertFalse(result.metadata.hasMergedOrUnpairedReads)
        XCTAssertNil(result.metadata.mergeEvidence)
        let primary = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: counted))
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: primary).layout, .strictlyInterleaved, "the file inside the bundle reads the same")
    }

    /// A count that names another file, a count that holds a merged or orphan
    /// read, and no count at all leave the merge evidence as it was.
    func testOnlyACountOfThisFilesPairsClearsTheMerge() throws {
        let headers = ["a/1", "a/2", "b/1", "b/2"]
        let otherFile = try makeMergeLineageChild(headers: headers, roles: pairsOnlyRoles(naming: "other.fastq", pairs: 2))
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: otherFile).layout, .mixedInterleaved)

        let withMerged = ReadClassification(files: [
            .init(filename: "reads.fastq", role: .pairedR1, readCount: 2),
            .init(filename: "reads.fastq", role: .pairedR2, readCount: 2),
            .init(filename: "reads.fastq", role: .merged, readCount: 1),
        ])
        let mixed = try makeMergeLineageChild(headers: headers, roles: withMerged)
        let result = FASTQReadLayoutClassifier.classify(inputURL: mixed)
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertTrue(result.metadata.hasMergedOrUnpairedReads)

        let withOrphan = ReadClassification(files: [
            .init(filename: "reads.fastq", role: .pairedR1, readCount: 2),
            .init(filename: "reads.fastq", role: .pairedR2, readCount: 2),
            .init(filename: "reads.fastq", role: .unpaired, readCount: 1),
        ])
        let orphaned = try makeMergeLineageChild(headers: headers, roles: withOrphan)
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: orphaned).layout, .mixedInterleaved)
    }

    /// A merge recipe whose merge left no merged read records the same count,
    /// so its file holds pairs and runs as pairs.
    func testAMergeRecipeThatLeftNoMergedReadScansAsPairsWhenItsCountSaysOnlyPairs() throws {
        let recipe = RecipeAppliedInfo(
            recipeID: "illuminaVSP2TargetEnrichment",
            recipeName: "VSP2",
            stepResults: [RecipeStepResult(stepName: "PE merge (normal, min overlap: 12)", tool: "fastp", durationSeconds: 1)]
        )
        let headers = ["a/1", "a/2", "b/1", "b/2"]
        let uncounted = try makeMergeLineageChild(headers: headers, roles: nil, recipe: recipe)
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: uncounted).layout, .mixedInterleaved)
        let counted = try makeMergeLineageChild(
            headers: headers,
            roles: pairsOnlyRoles(naming: "reads.fastq", pairs: 2),
            recipe: recipe
        )
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: counted).layout, .strictlyInterleaved)
    }
}
