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

    // MARK: - The pinned heap (Phase 2.10 FX47 (i))

    func testTheSeamKeepsItsHiddenName() {
        XCTAssertEqual(ManagedJavaHeapPolicy.pinnedHeapVariable, "LUNGFISH_MANAGED_JAVA_HEAP_PIN_GB")
    }

    func testAnEnvironmentWithNoPinLeavesTheLivePolicyAlone() {
        let heap = ManagedJavaHeapPolicy.heapGB(
            physicalMemoryBytes: 48 * gb, availableMemoryBytes: 14 * gb, environment: ["HOME": "/var/empty"]
        )
        XCTAssertEqual(heap, 6)
    }

    #if DEBUG
    func testAPinnedHeapIsTheHeapWhateverTheMemoryAndTheFloorSay() {
        let pinned = [ManagedJavaHeapPolicy.pinnedHeapVariable: "3"]
        XCTAssertEqual(
            ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 48 * gb, availableMemoryBytes: 14 * gb, environment: pinned), 3
        )
        XCTAssertEqual(
            ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 8 * gb, availableMemoryBytes: 2 * gb, minimumGB: 4, environment: pinned), 3,
            "the pin wins over the floor"
        )
        XCTAssertEqual(
            ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 256 * gb, availableMemoryBytes: 200 * gb, environment: [ManagedJavaHeapPolicy.pinnedHeapVariable: " 31 "]), 31
        )
    }

    func testAValueThatIsNotAWholeHeapInRangePinsNothing() {
        let live = ManagedJavaHeapPolicy.heapGB(physicalMemoryBytes: 48 * gb, availableMemoryBytes: 14 * gb, environment: [:])
        for value in ["", " ", "0", "-3", "32", "7.5", "seven", "3g", "99999999999999999999"] {
            let heap = ManagedJavaHeapPolicy.heapGB(
                physicalMemoryBytes: 48 * gb, availableMemoryBytes: 14 * gb,
                environment: [ManagedJavaHeapPolicy.pinnedHeapVariable: value]
            )
            XCTAssertEqual(heap, live, "'\(value)' pins nothing")
        }
    }

    /// The default environment is this process's, which is how the app and the CLI child read the pin.
    func testTheProcessEnvironmentIsTheDefaultSource() {
        let name = ManagedJavaHeapPolicy.pinnedHeapVariable
        let previous = getenv(name).map { String(cString: $0) }
        setenv(name, "5", 1)
        defer { if let previous { setenv(name, previous, 1) } else { unsetenv(name) } }
        XCTAssertEqual(ManagedJavaHeapPolicy.heapGB(minimumGB: 4), 5)
    }
    #endif

    func testLiveReadingIsSaneOnThisMachine() {
        let heap = ManagedJavaHeapPolicy.heapGB()
        XCTAssertGreaterThanOrEqual(heap, 1)
        XCTAssertLessThanOrEqual(heap, 31)
        XCTAssertNotNil(ManagedJavaHeapPolicy.currentAvailableMemoryBytes())
    }
}
