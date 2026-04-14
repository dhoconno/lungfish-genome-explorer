// ClassifierReadResolverTests.swift — Unit tests for the unified classifier extraction actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishWorkflow

final class ClassifierReadResolverTests: XCTestCase {

    // MARK: - resolveProjectRoot

    func testResolveProjectRoot_walksUpToLungfishMarker() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("resolver-root-\(UUID().uuidString)")
        let lungfishMarker = tempRoot.appendingPathComponent(".lungfish")
        let analyses = tempRoot.appendingPathComponent("analyses")
        let resultDir = analyses.appendingPathComponent("esviritu-20260401")
        try fm.createDirectory(at: lungfishMarker, withIntermediateDirectories: true)
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fakeResultPath = resultDir.appendingPathComponent("results.sqlite")
        fm.createFile(atPath: fakeResultPath.path, contents: Data())

        let resolved = ClassifierReadResolver.resolveProjectRoot(from: fakeResultPath)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            tempRoot.standardizedFileURL.path,
            "Expected to walk up to the .lungfish project root"
        )
    }

    func testResolveProjectRoot_noMarker_fallsBackToParentDirectory() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("resolver-nomarker-\(UUID().uuidString)")
        let resultDir = tempRoot.appendingPathComponent("loose-results")
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let fakeResultPath = resultDir.appendingPathComponent("results.sqlite")
        fm.createFile(atPath: fakeResultPath.path, contents: Data())

        let resolved = ClassifierReadResolver.resolveProjectRoot(from: fakeResultPath)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            resultDir.standardizedFileURL.path,
            "Expected fallback to the result path's parent directory"
        )
    }

    func testResolveProjectRoot_directoryInput_walksUpFromDirectoryItself() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("resolver-dir-\(UUID().uuidString)")
        let lungfishMarker = tempRoot.appendingPathComponent(".lungfish")
        let resultDir = tempRoot.appendingPathComponent("analyses/esviritu-20260401")
        try fm.createDirectory(at: lungfishMarker, withIntermediateDirectories: true)
        try fm.createDirectory(at: resultDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let resolved = ClassifierReadResolver.resolveProjectRoot(from: resultDir)
        XCTAssertEqual(
            resolved.standardizedFileURL.path,
            tempRoot.standardizedFileURL.path
        )
    }

    // MARK: - estimateReadCount

    func testEstimateReadCount_emptySelection_returnsZero() async throws {
        let resolver = ClassifierReadResolver()
        let count = try await resolver.estimateReadCount(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/nonexistent.sqlite"),
            selections: [],
            options: ExtractionOptions()
        )
        XCTAssertEqual(count, 0)
    }

    func testEstimateReadCount_allEmptySelectors_returnsZero() async throws {
        let resolver = ClassifierReadResolver()
        let count = try await resolver.estimateReadCount(
            tool: .esviritu,
            resultPath: URL(fileURLWithPath: "/tmp/nonexistent.sqlite"),
            selections: [
                ClassifierRowSelector(sampleId: "S1", accessions: [], taxIds: [])
            ],
            options: ExtractionOptions()
        )
        XCTAssertEqual(count, 0)
    }

    // MARK: - resolveBAMURL (per-tool)

    /// Helper: creates a throwaway directory layout that looks like a real
    /// classifier result for the purpose of BAM-path resolution only.
    /// Does NOT create a functional BAM — just a file at the expected path
    /// so `FileManager.fileExists` returns true.
    private func makeFakeClassifierResult(
        tool: ClassifierTool,
        sampleId: String
    ) throws -> (resultPath: URL, expectedBAM: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fake-\(tool.rawValue)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        switch tool {
        case .esviritu:
            let bam = root.appendingPathComponent("\(sampleId).sorted.bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))  // fake BGZF magic
            return (resultPath: root.appendingPathComponent("esviritu.sqlite"), expectedBAM: bam)

        case .taxtriage:
            let subdir = root.appendingPathComponent("minimap2")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            return (resultPath: root.appendingPathComponent("taxtriage.sqlite"), expectedBAM: bam)

        case .naomgs:
            let dbURL = root.appendingPathComponent("naomgs.sqlite")
            var db: OpaquePointer?
            guard sqlite3_open_v2(
                dbURL.path,
                &db,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK else {
                XCTFail("Failed to create NAO-MGS test database")
                throw NSError(domain: "ClassifierReadResolverTests", code: 1)
            }
            defer { sqlite3_close(db) }

            sqlite3_exec(
                db,
                """
                CREATE TABLE taxon_summaries (
                    sample TEXT NOT NULL,
                    tax_id INTEGER NOT NULL,
                    name TEXT NOT NULL,
                    hit_count INTEGER NOT NULL,
                    unique_read_count INTEGER NOT NULL,
                    avg_identity REAL NOT NULL,
                    avg_bit_score REAL NOT NULL,
                    avg_edit_distance REAL NOT NULL,
                    pcr_duplicate_count INTEGER NOT NULL,
                    accession_count INTEGER NOT NULL,
                    top_accessions_json TEXT NOT NULL,
                    bam_path TEXT,
                    bam_index_path TEXT,
                    PRIMARY KEY (sample, tax_id)
                );
                """,
                nil,
                nil,
                nil
            )

            let subdir = root.appendingPathComponent("bams")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            sqlite3_exec(
                db,
                """
                INSERT INTO taxon_summaries (
                    sample, tax_id, name, hit_count, unique_read_count,
                    avg_identity, avg_bit_score, avg_edit_distance,
                    pcr_duplicate_count, accession_count, top_accessions_json,
                    bam_path, bam_index_path
                ) VALUES (
                    '\(sampleId)', 123, 'Test virus', 1, 1,
                    99.0, 100.0, 0.0,
                    0, 1, '["ACC001"]',
                    'bams/\(sampleId).bam', 'bams/\(sampleId).bam.bai'
                );
                """,
                nil,
                nil,
                nil
            )
            return (resultPath: dbURL, expectedBAM: bam)

        case .nvd:
            let bamDir = root.appendingPathComponent("bam")
            try fm.createDirectory(at: bamDir, withIntermediateDirectories: true)
            let bam = bamDir.appendingPathComponent("\(sampleId).filtered.bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            return (resultPath: root.appendingPathComponent("nvd.sqlite"), expectedBAM: bam)

        case .kraken2:
            fatalError("kraken2 is not a BAM-backed tool")
        }
    }

    func testResolveBAMURL_esviritu_findsSiblingSortedBAM() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .esviritu, sampleId: "SRR123")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .esviritu,
            sampleId: "SRR123",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_taxtriage_findsMinimap2Subdir() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .taxtriage, sampleId: "S01")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .taxtriage,
            sampleId: "S01",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_naomgs_findsBamsSubdir() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .naomgs, sampleId: "S02")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .naomgs,
            sampleId: "S02",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_nvd_findsSiblingBAM() async throws {
        let (resultPath, expected) = try makeFakeClassifierResult(tool: .nvd, sampleId: "SampleX")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let resolver = ClassifierReadResolver()
        let resolved = try await resolver.testingResolveBAMURL(
            tool: .nvd,
            sampleId: "SampleX",
            resultPath: resultPath
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testResolveBAMURL_missingBAM_throwsBamNotFound() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let resultPath = root.appendingPathComponent("esviritu.sqlite")
        let resolver = ClassifierReadResolver()

        do {
            _ = try await resolver.testingResolveBAMURL(
                tool: .esviritu,
                sampleId: "SRR999",
                resultPath: resultPath
            )
            XCTFail("Expected bamNotFound error")
        } catch ClassifierExtractionError.bamNotFound(let sampleId) {
            XCTAssertEqual(sampleId, "SRR999")
        } catch {
            XCTFail("Expected bamNotFound, got \(error)")
        }
    }

    // MARK: - extractViaBAM end-to-end (real samtools)

    /// Path to the sarscov2 test fixture BAM (exists in Tests/Fixtures/sarscov2/).
    private func sarscov2FixtureBAM() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        // tests/LungfishWorkflowTests/Extraction/ClassifierReadResolverTests.swift
        // ↑ we walk up 4 levels to repo root, then into Tests/Fixtures/sarscov2
        let repoRoot = thisFile
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let bam = repoRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        guard FileManager.default.fileExists(atPath: bam.path) else {
            throw XCTSkip("sarscov2 test BAM not present at \(bam.path)")
        }
        return bam
    }

    /// Set up a fake "nvd" result directory pointing at the sarscov2 fixture BAM
    /// by symlinking the fixture BAM + index into the expected naming pattern.
    private func makeSarscov2ResultFixture(tool: ClassifierTool, sampleId: String) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("s2fixture-\(tool.rawValue)-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let fixtureBAM = try sarscov2FixtureBAM()
        let fixtureBAI = fixtureBAM.deletingPathExtension().appendingPathExtension("bam.bai")
        let fixtureBAIFallback = URL(fileURLWithPath: fixtureBAM.path + ".bai")
        let actualBAIFixture: URL
        if fm.fileExists(atPath: fixtureBAIFallback.path) {
            actualBAIFixture = fixtureBAIFallback
        } else if fm.fileExists(atPath: fixtureBAI.path) {
            actualBAIFixture = fixtureBAI
        } else {
            throw XCTSkip("sarscov2 BAI not present")
        }

        let bamDest: URL
        switch tool {
        case .nvd:
            try fm.createDirectory(at: root.appendingPathComponent("bam"), withIntermediateDirectories: true)
            bamDest = root.appendingPathComponent("bam/\(sampleId).filtered.bam")
        case .esviritu:
            bamDest = root.appendingPathComponent("\(sampleId).sorted.bam")
        case .taxtriage:
            try fm.createDirectory(at: root.appendingPathComponent("minimap2"), withIntermediateDirectories: true)
            bamDest = root.appendingPathComponent("minimap2/\(sampleId).bam")
        case .naomgs:
            try fm.createDirectory(at: root.appendingPathComponent("bams"), withIntermediateDirectories: true)
            bamDest = root.appendingPathComponent("bams/\(sampleId).sorted.bam")
        case .kraken2:
            fatalError("kraken2 not BAM-backed")
        }
        try fm.copyItem(at: fixtureBAM, to: bamDest)
        try fm.copyItem(at: actualBAIFixture, to: URL(fileURLWithPath: bamDest.path + ".bai"))
        return root.appendingPathComponent("fake-result.sqlite")
    }

    func testExtractViaBAM_nvd_producesFASTQFromFixture() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "s2")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        // Dig out the actual reference name from the BAM so we can target it.
        // For sarscov2 this is "MN908947.3" per TestFixtures, but we read
        // from the index to avoid hard-coding.
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "s2", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(format: .fastq, includeUnmappedMates: false),
            destination: .file(tempOut)
        )

        if case .file(let url, let n) = outcome {
            XCTAssertEqual(url.standardizedFileURL.path, tempOut.standardizedFileURL.path)
            XCTAssertGreaterThan(n, 0, "Expected non-zero reads from sarscov2 fixture")
        } else {
            XCTFail("Expected .file outcome, got \(outcome)")
        }
    }

    func testExtractViaBAM_multiSample_concatenatesOutputs() async throws {
        let resultPathA = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "A")
        let rootA = resultPathA.deletingLastPathComponent()
        let resultPathB = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "B")
        let rootB = resultPathB.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        // Same-root multi-sample: copy sample B's BAM into root A so both
        // samples live under the same result path, per spec.
        let bamDirA = rootA.appendingPathComponent("bam")
        try FileManager.default.copyItem(
            at: rootB.appendingPathComponent("bam/B.filtered.bam"),
            to: bamDirA.appendingPathComponent("B.filtered.bam")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: rootB.appendingPathComponent("bam/B.filtered.bam").path + ".bai"),
            to: URL(fileURLWithPath: bamDirA.appendingPathComponent("B.filtered.bam").path + ".bai")
        )

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory.appendingPathComponent("multi-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [
                ClassifierRowSelector(sampleId: "A", accessions: [region], taxIds: []),
                ClassifierRowSelector(sampleId: "B", accessions: [region], taxIds: []),
            ],
            options: ExtractionOptions(),
            destination: .file(tempOut)
        )
        XCTAssertGreaterThan(outcome.readCount, 0)
    }

    /// Extract sample A alone, sample B alone, and A+B together; assert
    /// count(A+B) == count(A) + count(B). Catches concatenation bugs and the
    /// stem-collision risk where two samples share the same sidecar prefix.
    func testExtractViaBAM_multiSample_countEquivalence() async throws {
        let resultPathA = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "A")
        let rootA = resultPathA.deletingLastPathComponent()
        let resultPathB = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "B")
        let rootB = resultPathB.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }

        // Copy sample B's BAM into root A so the combined extraction can
        // resolve both samples from the same result path.
        let bamDirAeq = rootA.appendingPathComponent("bam")
        try FileManager.default.copyItem(
            at: rootB.appendingPathComponent("bam/B.filtered.bam"),
            to: bamDirAeq.appendingPathComponent("B.filtered.bam")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: rootB.appendingPathComponent("bam/B.filtered.bam").path + ".bai"),
            to: URL(fileURLWithPath: bamDirAeq.appendingPathComponent("B.filtered.bam").path + ".bai")
        )

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let resolver = ClassifierReadResolver()

        let outA = FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID().uuidString).fastq")
        let outB = FileManager.default.temporaryDirectory.appendingPathComponent("b-\(UUID().uuidString).fastq")
        let outAB = FileManager.default.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString).fastq")
        defer {
            try? FileManager.default.removeItem(at: outA)
            try? FileManager.default.removeItem(at: outB)
            try? FileManager.default.removeItem(at: outAB)
        }

        let outcomeA = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [ClassifierRowSelector(sampleId: "A", accessions: [region], taxIds: [])],
            options: ExtractionOptions(),
            destination: .file(outA)
        )
        let outcomeB = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [ClassifierRowSelector(sampleId: "B", accessions: [region], taxIds: [])],
            options: ExtractionOptions(),
            destination: .file(outB)
        )
        let outcomeAB = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPathA,
            selections: [
                ClassifierRowSelector(sampleId: "A", accessions: [region], taxIds: []),
                ClassifierRowSelector(sampleId: "B", accessions: [region], taxIds: []),
            ],
            options: ExtractionOptions(),
            destination: .file(outAB)
        )

        XCTAssertGreaterThan(outcomeA.readCount, 0)
        XCTAssertGreaterThan(outcomeB.readCount, 0)
        XCTAssertEqual(
            outcomeAB.readCount,
            outcomeA.readCount + outcomeB.readCount,
            "Combined A+B extract should equal the sum of per-sample counts"
        )
    }

    /// Exercises the `options.format == .fasta` path. Verifies the output is a
    /// well-formed FASTA (`>` header lines alternating with sequence lines).
    /// `convertFASTQToFASTA` has ~40 lines of hand-rolled byte munging that
    /// was previously completely untested.
    func testExtractViaBAM_fastaFormat_producesValidFASTA() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "fa")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("out-\(UUID().uuidString).fasta")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "fa", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(format: .fasta, includeUnmappedMates: false),
            destination: .file(tempOut)
        )

        guard case .file(let url, let n) = outcome else {
            XCTFail("Expected .file outcome, got \(outcome)")
            return
        }
        XCTAssertGreaterThan(n, 0)

        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty, "FASTA output is empty")

        // Parse as UTF-8 lines and verify FASTA structure: header lines start
        // with '>', each header is followed by exactly one sequence line (the
        // resolver's converter discards the `+` and quality lines from the
        // FASTQ). Require at least one complete record.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        XCTAssertFalse(lines.isEmpty, "FASTA has no lines")
        XCTAssertEqual(lines.count % 2, 0, "FASTA should have an even number of header+sequence lines")

        var recordCount = 0
        for (i, line) in lines.enumerated() {
            if i % 2 == 0 {
                XCTAssertTrue(line.first == ">", "Expected header at line \(i), got: \(line)")
                recordCount += 1
            } else {
                XCTAssertFalse(line.first == ">", "Expected sequence at line \(i), got header: \(line)")
                XCTAssertFalse(line.isEmpty, "Empty sequence at line \(i)")
            }
        }
        XCTAssertGreaterThan(recordCount, 0, "No FASTA records parsed")
        XCTAssertEqual(recordCount, n, "FASTA record count should match outcome.readCount")
    }

    /// Exercises the `includeUnmappedMates: true` path. The sarscov2 fixture
    /// may not contain unmapped mates, so this test primarily pins the API
    /// surface: both flag settings should succeed and produce a non-zero
    /// count. `false` → `0x404` (exclude unmapped + duplicates + qcfail),
    /// `true` → `0x400` (exclude duplicates + qcfail only).
    func testExtractViaBAM_includeUnmappedMates_succeeds() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "um")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(
            bamURL: try sarscov2FixtureBAM(),
            runner: .shared
        )
        guard let region = bamRefs.first else {
            throw XCTSkip("sarscov2 BAM header has no references")
        }

        let tempOut = FileManager.default.temporaryDirectory
            .appendingPathComponent("um-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "um", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(format: .fastq, includeUnmappedMates: true),
            destination: .file(tempOut)
        )

        guard case .file(_, let n) = outcome else {
            XCTFail("Expected .file outcome, got \(outcome)")
            return
        }
        XCTAssertGreaterThan(n, 0, "Expected non-zero reads with includeUnmappedMates=true")
    }

    // MARK: - Destination routing

    func testDestination_bundle_createsLungfishfastqUnderProjectRoot() async throws {
        let fm = FileManager.default
        let projectRoot = fm.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
        let lungfishDir = projectRoot.appendingPathComponent(".lungfish")
        try fm.createDirectory(at: lungfishDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: projectRoot) }

        // Stand up an NVD fake result INSIDE the project so resolveProjectRoot walks up correctly.
        let resultDir = projectRoot.appendingPathComponent("analyses/nvd-20260401")
        let resultBamDir = resultDir.appendingPathComponent("bam")
        try fm.createDirectory(at: resultBamDir, withIntermediateDirectories: true)
        let fixtureBAM = try sarscov2FixtureBAM()
        let fixtureBAI: URL = {
            let bai = URL(fileURLWithPath: fixtureBAM.path + ".bai")
            if fm.fileExists(atPath: bai.path) { return bai }
            return fixtureBAM.deletingPathExtension().appendingPathExtension("bam.bai")
        }()
        let bamDest = resultBamDir.appendingPathComponent("s2.filtered.bam")
        try fm.copyItem(at: fixtureBAM, to: bamDest)
        try fm.copyItem(at: fixtureBAI, to: URL(fileURLWithPath: bamDest.path + ".bai"))
        let resultPath = resultDir.appendingPathComponent("fake.sqlite")

        let bamRefs = try await BAMRegionMatcher.readBAMReferences(bamURL: fixtureBAM, runner: .shared)
        guard let region = bamRefs.first else { throw XCTSkip("no BAM refs") }

        let metadata = ExtractionMetadata(
            sourceDescription: "sarscov2-fixture",
            toolName: "NVD",
            parameters: ["accession": region]
        )

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [
                ClassifierRowSelector(sampleId: "s2", accessions: [region], taxIds: [])
            ],
            options: ExtractionOptions(),
            destination: .bundle(
                projectRoot: projectRoot,
                displayName: "sarscov2-test-extract",
                metadata: metadata
            )
        )

        guard case .bundle(let bundleURL, let n) = outcome else {
            XCTFail("Expected .bundle outcome, got \(outcome)")
            return
        }
        XCTAssertTrue(bundleURL.pathExtension == "lungfishfastq",
                      "Expected .lungfishfastq bundle, got \(bundleURL.lastPathComponent)")
        XCTAssertTrue(bundleURL.path.hasPrefix(projectRoot.path),
                      "Bundle must land under the project root: \(bundleURL.path)")
        XCTAssertFalse(bundleURL.path.contains("/.lungfish/.tmp/"),
                      "Bundle must NOT land in .lungfish/.tmp/")
        XCTAssertGreaterThan(n, 0)
    }

    func testDestination_clipboard_returnsSerializedFASTQ() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "cb")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(bamURL: try sarscov2FixtureBAM(), runner: .shared)
        guard let region = bamRefs.first else { throw XCTSkip("no BAM refs") }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [ClassifierRowSelector(sampleId: "cb", accessions: [region], taxIds: [])],
            options: ExtractionOptions(format: .fastq),
            destination: .clipboard(format: .fastq, cap: 10_000)
        )
        guard case .clipboard(let payload, let byteCount, let n) = outcome else {
            XCTFail("Expected .clipboard outcome")
            return
        }
        XCTAssertFalse(payload.isEmpty)
        XCTAssertGreaterThan(byteCount, 0)
        XCTAssertGreaterThan(n, 0)
    }

    func testDestination_share_movesFileToStableLocation() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "sh")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(bamURL: try sarscov2FixtureBAM(), runner: .shared)
        guard let region = bamRefs.first else { throw XCTSkip("no BAM refs") }

        let shareDir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shareDir) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .nvd,
            resultPath: resultPath,
            selections: [ClassifierRowSelector(sampleId: "sh", accessions: [region], taxIds: [])],
            options: ExtractionOptions(),
            destination: .share(tempDirectory: shareDir)
        )
        guard case .share(let url, _) = outcome else {
            XCTFail("Expected .share outcome")
            return
        }
        XCTAssertTrue(url.path.hasPrefix(shareDir.path),
                      "Share file must land under the requested temp directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDestination_clipboard_capExceeded_throws() async throws {
        let resultPath = try makeSarscov2ResultFixture(tool: .nvd, sampleId: "cap")
        defer { try? FileManager.default.removeItem(at: resultPath.deletingLastPathComponent()) }
        let bamRefs = try await BAMRegionMatcher.readBAMReferences(bamURL: try sarscov2FixtureBAM(), runner: .shared)
        guard let region = bamRefs.first else { throw XCTSkip("no BAM refs") }

        let resolver = ClassifierReadResolver()
        do {
            _ = try await resolver.resolveAndExtract(
                tool: .nvd,
                resultPath: resultPath,
                selections: [ClassifierRowSelector(sampleId: "cap", accessions: [region], taxIds: [])],
                options: ExtractionOptions(),
                destination: .clipboard(format: .fastq, cap: 1)  // deliberately tiny
            )
            XCTFail("Expected clipboardCapExceeded error")
        } catch ClassifierExtractionError.clipboardCapExceeded {
            // ok
        } catch {
            XCTFail("Expected clipboardCapExceeded, got \(error)")
        }
    }

    // MARK: - extractViaKraken2

    /// Path to the kraken2-mini per-sample fixture, if present.
    private func kraken2MiniResultPath() throws -> URL {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // Extraction
            .deletingLastPathComponent() // LungfishWorkflowTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let sampleDir = repoRoot.appendingPathComponent("Tests/Fixtures/kraken2-mini/SRR35517702")
        guard FileManager.default.fileExists(atPath: sampleDir.path) else {
            throw XCTSkip("kraken2-mini fixture not present at \(sampleDir.path)")
        }
        return sampleDir
    }

    func testExtractViaKraken2_fixtureProducesFASTQ() async throws {
        let resultPath = try kraken2MiniResultPath()

        // Phase 2 fixture status: kraken2-mini/SRR35517702/ currently contains
        // only `classification-result.json` and `classification.kreport`. The
        // per-read kraken output (`classification.kraken`) and the source FASTQ
        // are both missing, so end-to-end extraction cannot run yet. Phase 7
        // fixture work will land a complete kraken2 fixture (kreport + per-read
        // output + source FASTQ) and remove this skip.
        //
        // The compatibility check below also tolerates a future layout where
        // the result lives in a `classification-YYYYMMDD/` subdirectory; if such
        // a directory ever appears we use it, otherwise we try the sample dir
        // itself. Either way the fixture is currently incomplete and we skip.
        let fm = FileManager.default
        let candidateDir: URL = {
            if let subdirs = try? fm.contentsOfDirectory(
                at: resultPath,
                includingPropertiesForKeys: [.isDirectoryKey]
            ),
               let subdir = subdirs.first(where: { url in
                   guard url.lastPathComponent.hasPrefix("classification-") else { return false }
                   let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                   return values?.isDirectory == true
               }) {
                return subdir
            }
            return resultPath
        }()

        // Check the per-read kraken output exists; if not, the fixture is the
        // current incomplete one and there's nothing extractViaKraken2 can do.
        let perReadOutput = candidateDir.appendingPathComponent("classification.kraken")
        guard fm.fileExists(atPath: perReadOutput.path) else {
            throw XCTSkip("kraken2-mini fixture is missing classification.kraken (per-read output); Phase 7 fixture work will land a complete fixture")
        }
        let classificationDir = candidateDir

        // We need at least one tax ID that has reads assigned. Load the tree
        // and pick the first non-zero clade count.
        let classResult = try ClassificationResult.load(from: classificationDir)
        let candidate = classResult.tree.allNodes().first(where: { $0.readsClade > 0 && $0.taxId != 0 })
        guard let taxon = candidate else {
            throw XCTSkip("kraken2-mini fixture has no taxa with classified reads")
        }

        let tempOut = FileManager.default.temporaryDirectory.appendingPathComponent("k2out-\(UUID().uuidString).fastq")
        defer { try? FileManager.default.removeItem(at: tempOut) }

        let resolver = ClassifierReadResolver()
        let outcome = try await resolver.resolveAndExtract(
            tool: .kraken2,
            resultPath: classificationDir,
            selections: [
                ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: [taxon.taxId])
            ],
            options: ExtractionOptions(),
            destination: .file(tempOut)
        )

        guard case .file(let url, let n) = outcome else {
            XCTFail("Expected .file outcome, got \(outcome)")
            return
        }
        XCTAssertEqual(url.standardizedFileURL.path, tempOut.standardizedFileURL.path)
        XCTAssertGreaterThan(n, 0, "Expected non-zero reads for taxon \(taxon.taxId)")
    }
}
