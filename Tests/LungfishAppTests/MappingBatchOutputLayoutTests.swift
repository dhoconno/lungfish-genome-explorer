// MappingBatchOutputLayoutTests.swift - Coverage for mapping fan-out batch
// directory grouping (BG3, batch-results-grouping campaign).
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class MappingBatchOutputLayoutTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-mapping-batch-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    private func request(sampleName: String) -> MappingRunRequest {
        MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [URL(fileURLWithPath: "/tmp/proj/\(sampleName).lungfishfastq", isDirectory: true)],
            referenceFASTAURL: URL(fileURLWithPath: "/tmp/proj/reference.fa"),
            projectURL: tempDir,
            outputDirectory: URL(fileURLWithPath: "/tmp/placeholder", isDirectory: true),
            sampleName: sampleName,
            threads: 4
        )
    }

    // MARK: - N > 1: grouped batch layout

    func testTwoRequestsYieldOneBatchDirectoryWithTwoNamedChildrenAndNoSiblingSingleRunDirs() throws {
        let requests = [request(sampleName: "SampleA"), request(sampleName: "SampleB")]

        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )

        XCTAssertEqual(sampleDirs.count, 2)

        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: analysesDir, includingPropertiesForKeys: nil
        )
        // Exactly one entry at the Analyses root: the batch directory. No
        // sibling `minimap2-<ts>` single-run directories.
        XCTAssertEqual(entries.count, 1)
        let batchDir = try XCTUnwrap(entries.first)
        XCTAssertTrue(batchDir.lastPathComponent.hasPrefix("minimap2-batch-"))

        XCTAssertEqual(sampleDirs[0].lastPathComponent, "SampleA")
        XCTAssertEqual(sampleDirs[1].lastPathComponent, "SampleB")
        XCTAssertEqual(sampleDirs[0].deletingLastPathComponent().standardizedFileURL, batchDir.standardizedFileURL)
        XCTAssertEqual(sampleDirs[1].deletingLastPathComponent().standardizedFileURL, batchDir.standardizedFileURL)

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleDirs[0].path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleDirs[1].path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// Ordering invariant (spec §3): sample directory names are precomputed
    /// in the original request order, not by whichever child happens to run
    /// first -- verified here by checking the returned array's order matches
    /// input order exactly (the array IS the precomputed order; there is no
    /// child-task reordering possible since this is a synchronous pure
    /// computation over the request list).
    func testSampleDirectoriesArePrecomputedInRequestOrder() throws {
        let requests = [
            request(sampleName: "Zebra"),
            request(sampleName: "Alpha"),
            request(sampleName: "Mike"),
        ]

        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )

        XCTAssertEqual(sampleDirs.map(\.lastPathComponent), ["Zebra", "Alpha", "Mike"])
    }

    func testDuplicateSampleNamesDedupWithNumericSuffixInRequestOrder() throws {
        let requests = [
            request(sampleName: "SampleA"),
            request(sampleName: "SampleA"),
            request(sampleName: "SampleA"),
        ]

        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )

        XCTAssertEqual(sampleDirs.map(\.lastPathComponent), ["SampleA", "SampleA-2", "SampleA-3"])
    }

    // MARK: - N == 1: unchanged flat layout (regression pin)

    func testSingleRequestReturnsNilSoCallerKeepsSingleRunBehaviorUnchanged() throws {
        let requests = [request(sampleName: "SampleA")]

        let sampleDirs = AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)

        XCTAssertNil(sampleDirs)

        // No batch directory (nor anything else) should have been created
        // as a side effect of the single-request path.
        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysesDir.path))
    }

    func testEmptyRequestsReturnsNil() {
        XCTAssertNil(AppDelegate.precomputedMappingBatchOutputDirectories(requests: [], in: tempDir))
    }

    // MARK: - Empty-batch cleanup (spec §6)

    func testCleanupRemovesBatchDirectoryWhenOnlyMetadataSidecarRemains() throws {
        let requests = [request(sampleName: "SampleA"), request(sampleName: "SampleB")]
        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )
        let batchDir = sampleDirs[0].deletingLastPathComponent()

        // Simulate every child failing: remove the (empty) per-sample dirs
        // it created, leaving only analysis-metadata.json behind, matching
        // what a real all-failed batch looks like on disk.
        for dir in sampleDirs {
            try? FileManager.default.removeItem(at: dir)
        }

        AppDelegate.cleanupBatchDirectoryIfEmpty(batchDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: batchDir.path))
    }

    func testCleanupKeepsBatchDirectoryWhenAnySampleEntryRemains() throws {
        let requests = [request(sampleName: "SampleA"), request(sampleName: "SampleB")]
        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )
        let batchDir = sampleDirs[0].deletingLastPathComponent()

        // Only the first child failed (its directory got cleaned up
        // upstream); the second child succeeded and left its directory
        // (with contents) behind.
        try? FileManager.default.removeItem(at: sampleDirs[0])
        try Data("bam-bytes".utf8).write(to: sampleDirs[1].appendingPathComponent("result.bam"))

        AppDelegate.cleanupBatchDirectoryIfEmpty(batchDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.path))
    }

    func testCleanupIsNoOpWhenBatchDirectoryDoesNotExist() {
        let missing = tempDir.appendingPathComponent("Analyses/minimap2-batch-does-not-exist", isDirectory: true)
        // Must not throw or crash.
        AppDelegate.cleanupBatchDirectoryIfEmpty(missing)
    }
}
