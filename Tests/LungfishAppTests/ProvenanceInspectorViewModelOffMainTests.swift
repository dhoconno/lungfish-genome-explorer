// ProvenanceInspectorViewModelOffMainTests.swift - Threading and stale-discard regression
// coverage for ProvenanceInspectorViewModel.load(item:)'s off-main sidecar lookup. See F6.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishWorkflow

/// Thread-safe capture box for the `loadThreadingProbe` hook. The probe closure is
/// `@Sendable` and fires from whatever thread `performLookup` actually runs on; this box lets
/// the (MainActor) test method read the captured value afterward. Idiom:
/// `ReferenceBundleAnnotationImportServiceOffMainTests.ThreadObservationBox`.
private final class ThreadObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _wasMainThread: Bool?
    private var _fired = false

    func record() {
        let isMain = Thread.isMainThread
        lock.lock()
        _wasMainThread = isMain
        _fired = true
        lock.unlock()
    }

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _fired
    }

    var wasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _wasMainThread
    }
}

/// Test-only controllable gate for `ProvenanceInspectorViewModel.loadFetchGate`. Lets a test
/// deterministically hold a lookup suspended mid-flight (inside the detached body, after the
/// threading probe fires but before the real sidecar walk/decode) so a second, superseding
/// `load(item:)` call can be started and completed first. Idiom:
/// `SequenceViewerInteractionAsyncBundleReadTests.GatedFetchController`.
private actor GatedFetchController {
    private var hasStarted = false
    private var isReleased = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        hasStarted = true
        let waitingStarts = startContinuations
        startContinuations.removeAll()
        for continuation in waitingStarts {
            continuation.resume()
        }
        if isReleased { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilFetchHasStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startContinuations.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waitingReleases = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in waitingReleases {
            continuation.resume()
        }
    }
}

@MainActor
final class ProvenanceInspectorViewModelOffMainTests: XCTestCase {

    override func tearDown() async throws {
        ProvenanceInspectorViewModel.loadThreadingProbe = nil
        ProvenanceInspectorViewModel.loadFetchGate = nil
        try await super.tearDown()
    }

    // MARK: - Threading regression (F6)
    //
    // Drives `load(item:)` from an actual `@MainActor` context (as every production call site
    // does -- `InspectorViewController+Notifications.swift`, `+PublicAPI.swift`) and asserts,
    // via a probe fired from inside `performLookup`'s `Task.detached` body, that the sidecar
    // walk/decode work is NOT running on the main thread.

    func testSidecarLookupRunsOffMainThreadWhenCalledFromMainActor() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let observation = ThreadObservationBox()
        ProvenanceInspectorViewModel.loadThreadingProbe = { observation.record() }

        let viewModel = ProvenanceInspectorViewModel()
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Reads"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertTrue(observation.fired, "loadThreadingProbe never fired -- test is not exercising the real code path")
        XCTAssertEqual(observation.wasMainThread, false, "provenance sidecar lookup ran on the main thread")
    }

    // MARK: - isLoading render-state regression (F6 review round 1)
    //
    // Round-1 review finding: `isLoading` was correctly maintained but write-only -- nothing
    // consumed it, so ProvenanceSection silently kept showing the previous selection's
    // provenance during a slow walk with no affordance. `ProvenanceSection`'s `if
    // viewModel.isLoading { ... ProgressView() ... }` (see
    // `ProvenanceSectionSourceTests.testProvenanceSectionRendersLoadingIndicatorFromViewModel`)
    // renders directly from this `@Observable` property, so proving the property's true/false
    // transitions here is equivalent to proving the section's loading affordance appears and
    // disappears at the right times.

    func testIsLoadingIsTrueWhileLookupInFlightAndFalseAfterCompletion() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeEnvelope(workflowName: "Gated Workflow", to: dir)

        let gate = GatedFetchController()
        ProvenanceInspectorViewModel.loadFetchGate = { await gate.waitUntilReleased() }

        let viewModel = ProvenanceInspectorViewModel()
        XCTAssertFalse(viewModel.isLoading, "Precondition: idle view model must not report loading")

        viewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Gated"
            )
        )

        // isLoading flips to true synchronously, before the detached lookup even starts.
        XCTAssertTrue(viewModel.isLoading, "isLoading must be true as soon as load(item:) is called")

        await gate.waitUntilFetchHasStarted()
        XCTAssertTrue(viewModel.isLoading, "isLoading must stay true while the sidecar lookup is in flight")

        await gate.release()
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertFalse(viewModel.isLoading, "isLoading must be false once the lookup has applied its result")
        XCTAssertEqual(viewModel.summary.workflowName, "Gated Workflow")
    }

    // MARK: - Stale-discard regression (F6)
    //
    // Controlled-ordering double-invoke: start a lookup, gate it mid-flight, start and complete
    // a second (superseding) lookup for a different item, then release the first. The first
    // lookup's result must not overwrite the second's, because its captured generation no
    // longer matches `loadGeneration` by the time it completes. Idiom:
    // `SequenceViewerInteractionAsyncBundleReadTests.testStaleAnnotationCopyCannotCommitAfterNewerCopyBegins`.

    func testStaleLookupCannotCommitAfterNewerLoadBegins() async throws {
        let staleDir = try makeTempDirectory()
        let freshDir = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: staleDir)
            try? FileManager.default.removeItem(at: freshDir)
        }

        // Distinct, independently-verifiable envelopes so the applied state unambiguously
        // identifies which lookup's result actually landed.
        try writeEnvelope(workflowName: "Stale Workflow", to: staleDir)
        try writeEnvelope(workflowName: "Fresh Workflow", to: freshDir)

        let gate = GatedFetchController()
        ProvenanceInspectorViewModel.loadFetchGate = { await gate.waitUntilReleased() }

        let viewModel = ProvenanceInspectorViewModel()

        // Start the stale load. It suspends inside performLookup's detached body at the gate,
        // having already captured its generation synchronously (loadGeneration += 1 happens
        // before the Task body's first await) when `load(item:)` returns.
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: staleDir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Stale"
            )
        )
        await gate.waitUntilFetchHasStarted()

        // Run a second, ungated load to completion. This bumps loadGeneration and applies its
        // own (correct) result.
        ProvenanceInspectorViewModel.loadFetchGate = nil
        viewModel.load(
            item: ProvenanceInspectableItem(
                url: freshDir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Fresh"
            )
        )
        try await waitUntilLoadCompletes(viewModel)

        XCTAssertEqual(viewModel.summary.workflowName, "Fresh Workflow")
        XCTAssertEqual(viewModel.currentItem?.url, freshDir)

        // Release the stale lookup. Its off-main work now completes, but its captured
        // generation no longer matches, so its apply() branch must be skipped entirely.
        await gate.release()

        // Give the released stale Task a chance to run to completion and (incorrectly, if the
        // generation guard were broken) overwrite the applied state.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            viewModel.summary.workflowName,
            "Fresh Workflow",
            "Stale sidecar lookup overwrote view-model state after a newer load had already committed"
        )
        XCTAssertEqual(viewModel.currentItem?.url, freshDir)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Fixtures

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-inspector-offmain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeEnvelope(workflowName: String, to dir: URL) throws {
        let input = dir.appendingPathComponent("input.fastq")
        let output = dir.appendingPathComponent("output.fastq")
        try Data("@r\nACGT\n+\n!!!!\n".utf8).write(to: input)
        try Data("@r\nACG\n+\n!!!\n".utf8).write(to: output)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        let outputDescriptor = try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output)
        let step = ProvenanceStep(
            toolName: "fastq-import",
            toolVersion: "1.0",
            argv: ["fastq-import", input.path],
            inputs: [inputDescriptor],
            outputs: [outputDescriptor],
            exitStatus: 0,
            wallTimeSeconds: 1
        )
        let envelope = ProvenanceEnvelope(
            workflowName: workflowName,
            workflowVersion: "2026.05",
            toolName: "lungfish-cli",
            toolVersion: "0.4.0",
            argv: ["lungfish-cli", "import", input.path],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
            files: [inputDescriptor, outputDescriptor],
            output: outputDescriptor,
            outputs: [outputDescriptor],
            steps: [step],
            wallTimeSeconds: 1,
            exitStatus: 0,
            stderr: ""
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: dir)
    }

    /// `load(item:)` is synchronous but resolves the sidecar lookup on a detached background
    /// task (see F6); this polls `isLoading` until that task has applied its result back on
    /// the main actor.
    private func waitUntilLoadCompletes(
        _ viewModel: ProvenanceInspectorViewModel,
        timeout: TimeInterval = 10
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isLoading {
            if Date() >= deadline {
                XCTFail("Timed out waiting for provenance load to complete")
                return
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
