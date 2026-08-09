// SavontBatchOutputLayoutTests.swift - Coverage for Savont fan-out batch
// directory grouping + completion barrier (BG5, batch-results-grouping
// campaign).
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow

@MainActor
final class SavontBatchOutputLayoutTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-savont-batch-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Bundle fixtures

    /// Builds a real `.lungfishfastq` bundle directory (empty contents are
    /// fine -- only the bundle's URL/display name matter to
    /// `independentSavontLaunchRequests`, which never reads inside it).
    private func makeBundle(named bundleName: String, in directory: URL) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(bundleName).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return bundleURL
    }

    private func makeLooseFASTQ(named fileName: String, in directory: URL) throws -> URL {
        let fileURL = directory.appendingPathComponent(fileName)
        try "@read\nACGT\n+\nIIII\n".write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func makePooledSavontRequest(inputURLs: [URL], outputDirectory: URL) -> FASTQOperationLaunchRequest {
        .savont(request: FASTQSavontClusteringRequest(
            inputURLs: inputURLs,
            outputDirectoryURL: outputDirectory,
            singleInputOutputName: nil,
            threads: 4,
            qualityValueCutoff: 90,
            minimumClusterSize: 3,
            minimumReadLength: nil,
            maximumReadLength: nil,
            singleStrand: false
        ))
    }

    private func outputName(of request: FASTQOperationLaunchRequest) -> String? {
        guard case .savont(let savontRequest) = request else { return nil }
        return savontRequest.singleInputOutputName
    }

    private func outputDirectoryURL(of request: FASTQOperationLaunchRequest) -> URL? {
        guard case .savont(let savontRequest) = request else { return nil }
        return savontRequest.outputDirectoryURL
    }

    // MARK: - N > 1: grouped batch layout, bundle-derived naming

    func testTwoBundlesYieldOneBatchDirectoryWithTwoBundleNamedFASTAChildrenAndNoSiblings() throws {
        let bundleA = try makeBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledSavontRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentSavontLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(outputName(of:)), ["SampleA.fasta", "SampleB.fasta"])

        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(at: analysesDir, includingPropertiesForKeys: nil)
        // Exactly one entry at the Analyses root: the batch directory. No
        // sibling per-input `savont-<ts>` single-run directories.
        XCTAssertEqual(entries.count, 1)
        let batchDir = try XCTUnwrap(entries.first)
        XCTAssertTrue(batchDir.lastPathComponent.hasPrefix("savont-batch-"))

        let childDirs = children.compactMap(outputDirectoryURL(of:))
        XCTAssertEqual(childDirs.count, 2)
        XCTAssertEqual(childDirs[0].standardizedFileURL, batchDir.standardizedFileURL)
        XCTAssertEqual(childDirs[1].standardizedFileURL, batchDir.standardizedFileURL)

        // Flat-file shape: no per-input subdirectory nesting, just files
        // directly inside the shared batch directory.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - Loose (non-bundle) input: falls back to input-file stem naming

    func testLooseFASTQInputsFallBackToInputStemNamingInsideBatchDirectory() throws {
        let looseA = try makeLooseFASTQ(named: "barcode01.fastq", in: tempDir)
        let looseB = try makeLooseFASTQ(named: "barcode02.fastq", in: tempDir)
        let pooledRequest = makePooledSavontRequest(inputURLs: [looseA, looseB], outputDirectory: tempDir)

        let children = pooledRequest.independentSavontLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 2)
        // `lungfishDisplayName` reduces a loose file to its own stem (no
        // `.lungfishfastq` suffix to strip), matching the spec's "fall back
        // to input-file stem for loose files" naming rule.
        XCTAssertEqual(children.map(outputName(of:)), ["barcode01.fasta", "barcode02.fasta"])
    }

    // MARK: - Collision dedup: two bundles with the same display name

    func testDuplicateBundleDisplayNamesDedupWithNumericSuffixesInInputOrder() throws {
        let subdirA = tempDir.appendingPathComponent("groupA", isDirectory: true)
        let subdirB = tempDir.appendingPathComponent("groupB", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subdirB, withIntermediateDirectories: true)
        let bundleA = try makeBundle(named: "sample", in: subdirA)
        let bundleB = try makeBundle(named: "sample", in: subdirB)

        let pooledRequest = makePooledSavontRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentSavontLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(outputName(of:)), ["sample.fasta", "sample-2.fasta"])
    }

    // MARK: - N == 1: unchanged flat layout (regression pin)

    func testSingleInputLeavesFlatOutputDirectoryUnchangedAndCreatesNoBatchDirectory() throws {
        let bundleA = try makeBundle(named: "SampleA", in: tempDir)
        let pooledRequest = makePooledSavontRequest(inputURLs: [bundleA], outputDirectory: tempDir)

        // Single-input path returns `self` unchanged (guard on
        // `batchRequest.inputURLs.count > 1`) -- no batch directory should
        // exist as a side effect, even with `projectURL` supplied.
        let children = pooledRequest.independentSavontLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )

        XCTAssertEqual(children.count, 1)
        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysesDir.path))
    }

    // MARK: - Combined/pooled regression pin: nil projectURL keeps pre-BG5 behavior

    func testNilProjectURLKeepsPreBG5FlatStemNamingAndCreatesNoBatchDirectory() throws {
        let looseA = try makeLooseFASTQ(named: "barcode01.fastq", in: tempDir)
        let looseB = try makeLooseFASTQ(named: "barcode02.fastq", in: tempDir)
        let pooledRequest = makePooledSavontRequest(inputURLs: [looseA, looseB], outputDirectory: tempDir)

        // projectURL omitted (defaults to nil): byte-for-byte pre-BG5
        // behavior -- stem-derived names, flat `outputDirectory`, no batch
        // directory created anywhere.
        let children = pooledRequest.independentSavontLaunchRequests(outputDirectory: tempDir)

        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children.map(outputName(of:)), [
            "barcode01-savont-clusters.fasta",
            "barcode02-savont-clusters.fasta",
        ])
        XCTAssertEqual(children.compactMap(outputDirectoryURL(of:)), [tempDir, tempDir])
        let analysesDir = tempDir.appendingPathComponent("Analyses", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysesDir.path))
    }

    // MARK: - Empty-batch cleanup (spec §6), via the shared hoisted helper

    func testSharedCleanupRemovesSavontBatchDirectoryWhenNoChildWroteAnyOutput() throws {
        let bundleA = try makeBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledSavontRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentSavontLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )
        let batchDir = try XCTUnwrap(children.compactMap(outputDirectoryURL(of:)).first)

        // Simulates every child failing before it wrote any output -- the
        // batch directory contains only `analysis-metadata.json`, no
        // per-input `.fasta` files.
        AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: batchDir.path))
    }

    func testSharedCleanupKeepsSavontBatchDirectoryWhenOneChildWroteOutput() throws {
        let bundleA = try makeBundle(named: "SampleA", in: tempDir)
        let bundleB = try makeBundle(named: "SampleB", in: tempDir)
        let pooledRequest = makePooledSavontRequest(inputURLs: [bundleA, bundleB], outputDirectory: tempDir)

        let children = pooledRequest.independentSavontLaunchRequests(
            outputDirectory: tempDir.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: tempDir
        )
        let batchDir = try XCTUnwrap(children.compactMap(outputDirectoryURL(of:)).first)
        let firstOutputName = try XCTUnwrap(outputName(of: children[0]))

        try Data("simulated FASTA output".utf8).write(to: batchDir.appendingPathComponent(firstOutputName))

        AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: batchDir.appendingPathComponent(firstOutputName).path))
    }

    // MARK: - Completion barrier (spec §6): deterministic ordering via isolated OperationCenter

    /// End-to-end proof, isolated from the real dispatch machinery (which
    /// needs a fully wired window/project/CLI environment), that the
    /// Savont fan-out's cleanup runs ONLY after every child operation has
    /// reached a terminal state -- and that the children themselves are
    /// NOT serialized (unlike the `.assemble` fan-out's sequential gate):
    /// this drives two simulated "children" through the same
    /// `pollUntilOperationTerminal`-gated `TaskGroup` barrier shape the
    /// production Savont dispatch uses, using an isolated `OperationCenter`
    /// instance so `start`/`complete`/`fail` can be driven deterministically
    /// (matching `OperationRoutingTests`' existing pattern for the
    /// analogous `.assemble` barrier tests).
    func testBarrierRunsCleanupOnlyAfterBothChildrenReachTerminalStateNotOnFirst() async throws {
        let center = OperationCenter()
        let opA = center.start(title: "Savont A", detail: "Running", operationType: .fastqOperation)
        let opB = center.start(title: "Savont B", detail: "Running", operationType: .fastqOperation)

        var cleanupRan = false
        let barrier = Task {
            await withTaskGroup(of: Void.self) { group in
                for opID in [opA, opB] {
                    group.addTask {
                        await MainSplitViewController.pollUntilOperationTerminal(
                            id: opID, center: center, pollInterval: .milliseconds(10)
                        )
                    }
                }
            }
            cleanupRan = true
        }

        // Only the first child completes; give the barrier several poll
        // intervals to (incorrectly) fire cleanup early if it only waited on
        // one child instead of all of them.
        XCTAssertTrue(center.complete(id: opA, detail: "Done"))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(cleanupRan, "cleanup must not run until ALL children are terminal")

        XCTAssertTrue(center.complete(id: opB, detail: "Done"))
        _ = await barrier.value

        XCTAssertTrue(cleanupRan, "cleanup must run once every child has reached a terminal state")
    }

    /// The children in the barrier are dispatched concurrently, not
    /// serialized: this proves both simulated children can be "running"
    /// simultaneously before either resolves (a sequential/one-at-a-time
    /// gate would never let both starts overlap without the first
    /// completing).
    func testBarrierAllowsBothChildrenToBeSimultaneouslyRunning() async throws {
        let center = OperationCenter()
        let opA = center.start(title: "Savont A", detail: "Running", operationType: .fastqOperation)
        let opB = center.start(title: "Savont B", detail: "Running", operationType: .fastqOperation)

        // Both children are concurrently in the `.running` state at once --
        // the concurrent-dispatch precondition the barrier must tolerate
        // (a serialized/.assemble-style gate would only ever start child B
        // after child A's own operation reached a terminal state).
        let items = center.items
        XCTAssertEqual(items.first(where: { $0.id == opA })?.state.isActive, true)
        XCTAssertEqual(items.first(where: { $0.id == opB })?.state.isActive, true)

        XCTAssertTrue(center.complete(id: opA, detail: "Done"))
        XCTAssertTrue(center.complete(id: opB, detail: "Done"))

        await withTaskGroup(of: Void.self) { group in
            for opID in [opA, opB] {
                group.addTask {
                    await MainSplitViewController.pollUntilOperationTerminal(
                        id: opID, center: center, pollInterval: .milliseconds(10)
                    )
                }
            }
        }
    }

    // MARK: - Source-inspection: dispatch site stays concurrent, barrier gates only cleanup

    /// BG5 review-lesson regression: the Savont dispatch loop itself must
    /// stay a plain concurrent `for` loop over `independentRequests` with NO
    /// per-iteration `await` on terminal state (that would silently
    /// re-serialize execution, defeating the "keep the children concurrent"
    /// requirement) -- only a SEPARATE `Task` after the loop may await
    /// completion, and it must do so via the static, `self`-free
    /// `pollUntilOperationTerminal` (not `self.awaitOperationTerminal`), so
    /// the barrier and the cleanup it gates still run if `self` deallocates
    /// mid-batch.
    func testSavontDispatchLoopStaysConcurrentAndBarrierUsesStaticSelfFreePoll() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift"
            ),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "if case .savont(let batchRequest) = request,"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "// Per-bundle short-read assembly (MB-2)"))
        let savontBlock = String(source[start.lowerBound..<end.lowerBound])

        // Dispatch loop: plain concurrent `for`, no `await` inside it.
        let dispatchLoopStart = try XCTUnwrap(savontBlock.range(
            of: "let childOpIDs: [UUID] = independentRequests.compactMap { independentRequest in"
        ))
        let dispatchLoopEnd = try XCTUnwrap(savontBlock.range(
            of: "\n            }\n", range: dispatchLoopStart.upperBound..<savontBlock.endIndex
        ))
        let dispatchLoopBody = savontBlock[dispatchLoopStart.upperBound..<dispatchLoopEnd.lowerBound]
        XCTAssertFalse(dispatchLoopBody.contains("await "), "dispatch loop must not await per-child completion")

        // Barrier: a separate `Task` using the static, self-free poll.
        XCTAssertTrue(savontBlock.contains("Task {"))
        XCTAssertTrue(savontBlock.contains("await Self.pollUntilOperationTerminal(id: opID)"))
        XCTAssertFalse(savontBlock.contains("self.awaitOperationTerminal"))

        // The barrier's `Task {` sits AFTER the dispatch loop finishes, and
        // cleanup sits after the barrier's `withTaskGroup` call.
        let dispatchRange = try XCTUnwrap(savontBlock.range(of: "runFASTQOperationLaunchRequestValidated("))
        let taskRange = try XCTUnwrap(savontBlock.range(of: "Task {"))
        let taskGroupRange = try XCTUnwrap(savontBlock.range(of: "await withTaskGroup(of: Void.self)"))
        let cleanupRange = try XCTUnwrap(savontBlock.range(of: "AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDirectory)"))
        XCTAssertLessThan(dispatchRange.lowerBound, taskRange.lowerBound)
        XCTAssertLessThan(taskRange.lowerBound, taskGroupRange.lowerBound)
        XCTAssertLessThan(taskGroupRange.lowerBound, cleanupRange.lowerBound)
    }
}
