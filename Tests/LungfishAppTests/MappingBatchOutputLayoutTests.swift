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
    //
    // These tests deliberately do NOT touch the sample directories that
    // `precomputedMappingBatchOutputDirectories` pre-creates -- that
    // precompute step creates every child's (empty) sample directory up
    // front, in request order, BEFORE any child dispatch, so "every child
    // failed before writing output" and "the batch was cancelled before any
    // child ran" are both represented on disk as a batch directory full of
    // still-empty sample directories, never as a batch directory with
    // missing sample directories. A test that pre-deletes the sample dirs
    // before calling cleanup exercises a state production never produces
    // (review fix, BG3 round 1).

    func testCleanupRemovesBatchDirectoryWhenAllPrecreatedSampleDirsAreStillEmpty() throws {
        let requests = [request(sampleName: "SampleA"), request(sampleName: "SampleB")]
        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )
        let batchDir = sampleDirs[0].deletingLastPathComponent()

        // Simulates every child failing before it wrote any output: the
        // precomputed sample directories exist (empty) exactly as the
        // precompute step left them; nothing here removes or populates
        // them.

        AppDelegate.cleanupBatchDirectoryIfEmpty(batchDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: batchDir.path))
    }

    func testCleanupKeepsBatchDirectoryWhenOneSampleDirHasPartialOutput() throws {
        let requests = [request(sampleName: "SampleA"), request(sampleName: "SampleB")]
        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )
        let batchDir = sampleDirs[0].deletingLastPathComponent()

        // SampleA failed before writing anything (its precomputed directory
        // stays empty, exactly as precomputed). SampleB failed AFTER
        // writing partial output -- its precomputed directory now has a
        // file in it. The whole batch directory must survive: SampleB's
        // partial output is real content that must not be silently
        // deleted.
        try Data("partial-bam-bytes".utf8).write(to: sampleDirs[1].appendingPathComponent("result.bam"))

        AppDelegate.cleanupBatchDirectoryIfEmpty(batchDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleDirs[0].path), "SampleA's empty dir must not be individually removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleDirs[1].appendingPathComponent("result.bam").path))
    }

    /// Cancellation shape (spec §6): the batch is cancelled after the first
    /// child produces output but before the second child ever starts. The
    /// first child's directory has content; the second's precomputed
    /// directory was created up front but the child that would have
    /// populated it never ran -- it stays empty. The batch directory must
    /// survive because of the first child's real output, and the cleanup
    /// must reach this conclusion without any child-side cleanup ever
    /// having touched the second (empty) directory.
    func testCleanupKeepsBatchDirectoryOnCancellationWithOneCompletedAndOneNeverStartedChild() throws {
        let requests = [request(sampleName: "SampleA"), request(sampleName: "SampleB")]
        let sampleDirs = try XCTUnwrap(
            AppDelegate.precomputedMappingBatchOutputDirectories(requests: requests, in: tempDir)
        )
        let batchDir = sampleDirs[0].deletingLastPathComponent()

        try Data("bam-bytes".utf8).write(to: sampleDirs[0].appendingPathComponent("result.bam"))
        // sampleDirs[1] is left exactly as precomputed: created, empty --
        // its child never ran before the batch was cancelled.

        AppDelegate.cleanupBatchDirectoryIfEmpty(batchDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sampleDirs[1].path), "unstarted child's empty dir must not be individually removed")
    }

    func testCleanupIsNoOpWhenBatchDirectoryDoesNotExist() {
        let missing = tempDir.appendingPathComponent("Analyses/minimap2-batch-does-not-exist", isDirectory: true)
        // Must not throw or crash.
        AppDelegate.cleanupBatchDirectoryIfEmpty(missing)
    }
}
