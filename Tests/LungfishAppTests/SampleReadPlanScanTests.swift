// SampleReadPlanScanTests.swift - Bounded, incremental per-sample scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

private actor ScanGate {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var started = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func enter() async {
        running += 1
        started += 1
        peak = max(peak, running)
        if !open {
            await withCheckedContinuation { waiters.append($0) }
        }
        running -= 1
    }

    func release() {
        open = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

final class SampleReadPlanScanTests: XCTestCase {
    private func samples(_ count: Int) -> [MetagenomicsSampleInput] {
        (0..<count).map {
            MetagenomicsSampleInput(sampleId: "S\($0)", fastq1: URL(fileURLWithPath: "/tmp/S\($0).fastq"), fastq2: nil)
        }
    }

    /// Polls a condition on the clock, never a fixed number of yields.
    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testEverySampleYieldedExactlyOnce() async {
        let input = samples(25)
        var seen: [String: Int] = [:]
        for await (id, value) in SampleReadPlanScan.stream(samples: input, width: 3, work: { $0.sampleId + "!" }) {
            XCTAssertEqual(value, id + "!")
            seen[id, default: 0] += 1
        }
        XCTAssertEqual(Set(seen.keys), Set(input.map(\.sampleId)))
        XCTAssertTrue(seen.values.allSatisfy { $0 == 1 })
    }

    func testConcurrencyNeverExceedsWidth() async {
        let gate = ScanGate()
        let input = samples(12)
        let stream = SampleReadPlanScan.stream(samples: input, width: 3, work: { _ in await gate.enter() })
        let consumer = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        let filled = await waitUntil { await gate.running == 3 }
        XCTAssertTrue(filled)
        let peakBeforeRelease = await gate.peak
        XCTAssertEqual(peakBeforeRelease, 3)
        await gate.release()
        let count = await consumer.value
        XCTAssertEqual(count, 12)
        let peak = await gate.peak
        XCTAssertLessThanOrEqual(peak, 3)
    }

    func testCancellingConsumerStopsNewWork() async {
        let gate = ScanGate()
        let input = samples(50)
        let stream = SampleReadPlanScan.stream(samples: input, width: 2, work: { _ in await gate.enter() })
        let consumer = Task {
            for await _ in stream {}
        }
        let filled = await waitUntil { await gate.running == 2 }
        XCTAssertTrue(filled)
        consumer.cancel()
        await consumer.value
        await gate.release()
        let drained = await waitUntil { await gate.running == 0 }
        XCTAssertTrue(drained)
        let started = await gate.started
        XCTAssertLessThan(started, 50)
    }
}
