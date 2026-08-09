// BundleManifestMutationSerializerTests.swift - Regression coverage for per-bundle manifest
// mutation serialization (round-2 review fix). Before this fix,
// ReferenceBundleAnnotationImportService.attachAnnotationTrack's Task.detached hop removed the
// implicit @MainActor serialization that used to protect concurrent manifest read-modify-write
// against the SAME bundle, so two concurrent attaches could interleave and silently drop a
// track (last write wins).
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Thread-safe append-only log so overlapping `run` closures (running on arbitrary
/// cooperative-pool threads) can record ordering without a data race.
private final class OrderingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func record(_ event: String) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }
}

final class BundleManifestMutationSerializerTests: XCTestCase {

    /// Two `run` calls for the SAME bundle URL must never overlap: the second call's
    /// closure must not start until the first call's closure has fully finished. This is
    /// verified with a real timing gate (not just launch-and-hope): the first closure
    /// blocks on a signal that only the test unblocks after confirming the second call
    /// has been queued (but not yet started, which the log proves).
    func testSameBundleRunsAreFullySerialized() async throws {
        let serializer = BundleManifestMutationSerializer()
        let bundleURL = URL(fileURLWithPath: "/tmp/BundleManifestMutationSerializerTests/shared.lungfishref")
        let log = OrderingLog()
        let firstMayFinish = AsyncGate()

        async let first: Void = serializer.run(bundleURL: bundleURL) {
            log.record("first-start")
            await firstMayFinish.wait()
            log.record("first-end")
        }

        // Give the first call a moment to actually be running (not just queued) before
        // queuing the second, so the second call provably arrives while the first is
        // in-flight -- the exact concurrent-import scenario from the regression.
        while !log.events.contains("first-start") {
            await Task.yield()
        }

        async let second: Void = serializer.run(bundleURL: bundleURL) {
            log.record("second-start")
        }

        // Let the second call's `run` invocation actually queue behind the first before
        // releasing the first, so the ordering assertion below is meaningful.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(log.events.contains("second-start"), "second run must not start while the first is still in-flight")

        await firstMayFinish.signal()
        _ = try await (first, second)

        XCTAssertEqual(log.events, ["first-start", "first-end", "second-start"])
    }

    /// Two `run` calls for DIFFERENT bundle URLs must NOT block each other -- the
    /// per-bundle serializer must not degrade into a global lock (that would defeat the
    /// off-main performance intent of the `Task.detached` change this fix preserves).
    func testDifferentBundlesRunConcurrently() async throws {
        let serializer = BundleManifestMutationSerializer()
        let bundleA = URL(fileURLWithPath: "/tmp/BundleManifestMutationSerializerTests/a.lungfishref")
        let bundleB = URL(fileURLWithPath: "/tmp/BundleManifestMutationSerializerTests/b.lungfishref")
        let log = OrderingLog()
        let aMayFinish = AsyncGate()

        async let a: Void = serializer.run(bundleURL: bundleA) {
            log.record("a-start")
            await aMayFinish.wait()
            log.record("a-end")
        }

        while !log.events.contains("a-start") {
            await Task.yield()
        }

        // b must be able to start (and finish) while a is still blocked, proving the two
        // bundle paths do not share a lock.
        async let b: Void = serializer.run(bundleURL: bundleB) {
            log.record("b-start")
            log.record("b-end")
        }
        _ = try await b

        XCTAssertTrue(log.events.contains("b-start"), "run for a different bundle must not be blocked by an in-flight run for another bundle")
        XCTAssertFalse(log.events.contains("a-end"), "bundle A's run must still be blocked at this point")

        await aMayFinish.signal()
        _ = try await a

        XCTAssertEqual(log.events, ["a-start", "b-start", "b-end", "a-end"])
    }

    /// A throwing `work` closure must propagate its error to the caller, and must not wedge
    /// the queue for later callers on the same bundle.
    func testThrowingWorkPropagatesErrorAndDoesNotWedgeTheQueue() async throws {
        struct Boom: Error {}
        let serializer = BundleManifestMutationSerializer()
        let bundleURL = URL(fileURLWithPath: "/tmp/BundleManifestMutationSerializerTests/throws.lungfishref")

        do {
            _ = try await serializer.run(bundleURL: bundleURL) {
                throw Boom()
            }
            XCTFail("Expected Boom to propagate")
        } catch is Boom {
            // expected
        }

        // A later call for the same bundle must still run normally.
        let value = try await serializer.run(bundleURL: bundleURL) { 42 }
        XCTAssertEqual(value, 42)
    }
}

/// Minimal single-shot async gate: `wait()` suspends until `signal()` is called (from
/// anywhere). Built on `AsyncStream` rather than a semaphore so it works safely from
/// Swift Concurrency tasks without blocking a thread.
private actor AsyncGate {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        isSignaled = true
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume()
        }
    }
}
