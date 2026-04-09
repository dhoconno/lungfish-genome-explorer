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
}
