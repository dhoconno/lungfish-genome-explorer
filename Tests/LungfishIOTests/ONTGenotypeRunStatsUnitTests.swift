// ONTGenotypeRunStatsUnitTests.swift - The genotype run stats carry the unit of their input total
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ONTGenotypeRunStatsUnitTests: XCTestCase {
    func testStatsLoaderReadsTheUnitAndTolerateItsAbsence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-stats-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fragments = directory.appendingPathComponent("fragments.json")
        try #"{"totalInputReads": 376, "totalInputReadsUnit": "fragments", "retainedUniqueReads": 376, "retainedUniquePercentOfTotalReads": 100.0}"#
            .write(to: fragments, atomically: true, encoding: .utf8)
        let stats = try ONTGenotypeRunStats.load(from: fragments)
        XCTAssertEqual(stats.totalInputReads, 376)
        XCTAssertEqual(stats.totalInputReadsUnit, "fragments")
        XCTAssertEqual(stats.retainedUniquePercentOfTotalReads, 100.0)

        // Stats written before the unit existed still load, with no unit.
        let legacy = directory.appendingPathComponent("legacy.json")
        try #"{"totalInputReads": 752, "retainedUniqueReads": 376, "retainedUniquePercentOfTotalReads": 50.0}"#
            .write(to: legacy, atomically: true, encoding: .utf8)
        let legacyStats = try ONTGenotypeRunStats.load(from: legacy)
        XCTAssertEqual(legacyStats.totalInputReads, 752)
        XCTAssertNil(legacyStats.totalInputReadsUnit)
    }
}
