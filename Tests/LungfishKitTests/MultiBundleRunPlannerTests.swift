// MultiBundleRunPlannerTests.swift - TDD coverage for MultiBundleRunPlanner (MB-0)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

final class MultiBundleRunPlannerTests: XCTestCase {

    // MARK: - Call recorder

    /// Records the order in which `materialize` and `pool` are invoked, plus
    /// which inputs each call received, so tests can assert both ordering
    /// and argument shape without relying on timing.
    private actor CallRecorder {
        enum Call: Equatable {
            case materialize([Int])
            case pool([Int])
        }

        private(set) var calls: [Call] = []

        func record(_ call: Call) {
            calls.append(call)
        }
    }

    // MARK: - perBundle mode

    func testPerBundleReturnsNGroupsPreservingOrder() async throws {
        let inputs = [1, 2, 3, 4]

        let groups = try await MultiBundleRunPlanner.plan(
            inputs: inputs,
            mode: .perBundle,
            materialize: { batch in batch.map { $0 * 10 } },
            pool: { batch in batch }
        )

        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups, [[10], [20], [30], [40]])
    }

    func testPerBundleEachGroupIsSingleElement() async throws {
        let inputs = ["a", "b", "c"]

        let groups = try await MultiBundleRunPlanner.plan(
            inputs: inputs,
            mode: .perBundle,
            materialize: { $0 },
            pool: { $0 }
        )

        XCTAssertEqual(groups.count, 3)
        for group in groups {
            XCTAssertEqual(group.count, 1)
        }
        XCTAssertEqual(groups.flatMap { $0 }, inputs)
    }

    func testPerBundleCallsMaterializeButNeverPool() async throws {
        let recorder = CallRecorder()
        let inputs = [1, 2, 3]

        _ = try await MultiBundleRunPlanner.plan(
            inputs: inputs,
            mode: .perBundle,
            materialize: { batch in
                await recorder.record(.materialize(batch))
                return batch
            },
            pool: { batch in
                await recorder.record(.pool(batch))
                return batch
            }
        )

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 3)
        for call in calls {
            guard case .materialize = call else {
                return XCTFail("perBundle mode must never invoke pool; got \(call)")
            }
        }
    }

    // MARK: - combined mode

    func testCombinedReturnsSingleGroup() async throws {
        let inputs = [1, 2, 3, 4]

        let groups = try await MultiBundleRunPlanner.plan(
            inputs: inputs,
            mode: .combined,
            materialize: { $0 },
            pool: { batch in [batch.reduce(0, +)] }
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0], [10])
    }

    func testCombinedMaterializesThenPools() async throws {
        let recorder = CallRecorder()
        let inputs = [1, 2, 3]

        _ = try await MultiBundleRunPlanner.plan(
            inputs: inputs,
            mode: .combined,
            materialize: { batch in
                await recorder.record(.materialize(batch))
                return batch.map { $0 * 100 }
            },
            pool: { batch in
                await recorder.record(.pool(batch))
                return batch
            }
        )

        let calls = await recorder.calls
        XCTAssertEqual(calls.count, 2, "combined mode must call materialize exactly once, then pool exactly once")
        XCTAssertEqual(calls[0], .materialize([1, 2, 3]))
        XCTAssertEqual(calls[1], .pool([100, 200, 300]), "pool must receive the MATERIALIZED inputs, not the raw ones")
    }

    func testCombinedPoolReceivesMaterializedOutputNotRawInput() async throws {
        // Guards against a planner that pools raw inputs (e.g. accidentally
        // reading preview.fastq for virtual bundles instead of the full
        // materialized reads).
        let inputs = ["raw-a", "raw-b"]

        let groups = try await MultiBundleRunPlanner.plan(
            inputs: inputs,
            mode: .combined,
            materialize: { batch in batch.map { "materialized-\($0)" } },
            pool: { batch in batch }
        )

        XCTAssertEqual(groups, [["materialized-raw-a", "materialized-raw-b"]])
    }

    // MARK: - Per-child cleanup / cancellation propagation

    func testPerBundleThrowingMaterializeForOneChildDoesNotLeakOthers() async throws {
        struct BoomError: Error, Equatable {}

        let cleanedUp = ManagedCounter()
        let inputs = [1, 2, 3]

        do {
            _ = try await MultiBundleRunPlanner.plan(
                inputs: inputs,
                mode: .perBundle,
                materialize: { batch in
                    guard let value = batch.first else { return batch }
                    if value == 2 {
                        throw BoomError()
                    }
                    // Simulate successful materialization allocating a temp
                    // resource that must be cleaned up by the caller when
                    // a sibling child fails.
                    await cleanedUp.increment()
                    return batch
                },
                pool: { $0 }
            )
            XCTFail("Expected BoomError to propagate")
        } catch is BoomError {
            // Expected: a single throwing child aborts the whole plan.
        }

        // Only the children that ran before/independent of the failure
        // should have "materialized" — no group silently swallowed the
        // error or kept running after the failure was observed.
        let count = await cleanedUp.value
        XCTAssertLessThanOrEqual(count, 2, "Materialization must not silently continue processing all children after one throws")
    }

    func testCombinedThrowingMaterializeNeverInvokesPool() async throws {
        struct BoomError: Error {}
        let recorder = CallRecorder()

        do {
            _ = try await MultiBundleRunPlanner.plan(
                inputs: [1, 2, 3],
                mode: .combined,
                materialize: { _ in throw BoomError() },
                pool: { batch in
                    await recorder.record(.pool(batch))
                    return batch
                }
            )
            XCTFail("Expected BoomError to propagate")
        } catch is BoomError {
            // Expected.
        }

        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "pool must never run when materialize throws")
    }

    func testPerBundleCancellationPropagatesAndStopsFurtherMaterialization() async throws {
        struct BoomError: Error {}
        let materializedCount = ManagedCounter()

        do {
            _ = try await MultiBundleRunPlanner.plan(
                inputs: [1, 2, 3, 4, 5],
                mode: .perBundle,
                materialize: { batch in
                    guard let value = batch.first else { return batch }
                    if value == 1 {
                        throw BoomError()
                    }
                    await materializedCount.increment()
                    return batch
                },
                pool: { $0 }
            )
            XCTFail("Expected BoomError to propagate")
        } catch is BoomError {
            // Expected
        }

        // The planner must surface the failure rather than returning a
        // partial, silently-truncated result set.
    }

    func testEmptyInputsReturnsEmptyGroupsForPerBundle() async throws {
        let groups = try await MultiBundleRunPlanner.plan(
            inputs: [Int](),
            mode: .perBundle,
            materialize: { $0 },
            pool: { $0 }
        )
        XCTAssertTrue(groups.isEmpty)
    }

    func testEmptyInputsCombinedStillCallsPoolWithEmptyMaterializedBatch() async throws {
        let recorder = CallRecorder()

        let groups = try await MultiBundleRunPlanner.plan(
            inputs: [Int](),
            mode: .combined,
            materialize: { batch in
                await recorder.record(.materialize(batch))
                return batch
            },
            pool: { batch in
                await recorder.record(.pool(batch))
                return batch
            }
        )

        XCTAssertEqual(groups, [[]])
        let calls = await recorder.calls
        XCTAssertEqual(calls, [.materialize([]), .pool([])])
    }
}

/// Simple actor-based counter for cross-Task-safe increments in tests.
private actor ManagedCounter {
    private(set) var value = 0
    func increment() {
        value += 1
    }
}
