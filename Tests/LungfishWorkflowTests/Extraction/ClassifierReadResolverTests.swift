// ClassifierReadResolverTests.swift — Unit tests for the unified classifier extraction actor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
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
            let subdir = root.appendingPathComponent("bams")
            try fm.createDirectory(at: subdir, withIntermediateDirectories: true)
            let bam = subdir.appendingPathComponent("\(sampleId).sorted.bam")
            fm.createFile(atPath: bam.path, contents: Data([0x1F, 0x8B]))
            return (resultPath: root.appendingPathComponent("naomgs.sqlite"), expectedBAM: bam)

        case .nvd:
            let bam = root.appendingPathComponent("\(sampleId).bam")
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
            bamDest = root.appendingPathComponent("\(sampleId).bam")
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
        try FileManager.default.copyItem(
            at: rootB.appendingPathComponent("B.bam"),
            to: rootA.appendingPathComponent("B.bam")
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: rootB.appendingPathComponent("B.bam").path + ".bai"),
            to: URL(fileURLWithPath: rootA.appendingPathComponent("B.bam").path + ".bai")
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
}
