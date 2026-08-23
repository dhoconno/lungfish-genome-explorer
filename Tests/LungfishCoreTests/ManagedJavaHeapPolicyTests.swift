// ManagedJavaHeapPolicyTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class ManagedJavaHeapPolicyTests: XCTestCase {
    private let gb: UInt64 = 1024 * 1024 * 1024

    func testFortyEightGigabyteMachineGetsAThirdNotSixtyPercent() {
        // The 2026-08-22 OOM: 60 percent of 48 GB was a 28 GB JVM next to a 16 GB kraken2.
        let heap = ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 48 * gb, availableMemoryBytes: nil)
        XCTAssertEqual(heap, 16)
    }

    func testAvailableMemoryCapsTheHeapWhenAnotherToolIsResident() {
        // 48 GB machine but only 14 GB free while kraken2 holds its database.
        let heap = ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 48 * gb, availableMemoryBytes: 14 * gb)
        XCTAssertEqual(heap, 6)
    }

    func testMinimumFloorHoldsOnSmallOrBusyMachines() {
        XCTAssertEqual(ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 8 * gb, availableMemoryBytes: 2 * gb), 4)
        XCTAssertEqual(ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 8 * gb, availableMemoryBytes: 2 * gb, minimumGB: 1), 1)
    }

    func testCompressedOopsCeilingHolds() {
        let heap = ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 256 * gb, availableMemoryBytes: 200 * gb)
        XCTAssertEqual(heap, 31)
    }

    func testLiveReadingIsSaneOnThisMachine() {
        let heap = ManagedJavaHeapPolicy.heapGB()
        XCTAssertGreaterThanOrEqual(heap, 1)
        XCTAssertLessThanOrEqual(heap, 31)
        XCTAssertNotNil(ManagedJavaHeapPolicy.currentAvailableMemoryBytes())
    }
}
