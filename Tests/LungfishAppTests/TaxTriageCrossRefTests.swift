// TaxTriageCrossRefTests.swift - Tests for TaxTriage cross-reference sidecar persistence
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class TaxTriageCrossRefTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaxTriageCrossRefTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - TaxTriageCrossRef Codable

    func testCrossRefRoundTrip() throws {
        let ref = TaxTriageCrossRef(
            resultDirectory: "/Users/test/results/taxtriage-20250325-143022",
            runId: "taxtriage-20250325-143022",
            sampleId: "SampleA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            batchSampleCount: 3
        )

        try MetagenomicsBatchResultStore.saveTaxTriageRef(ref, to: tempDir)

        let loaded = MetagenomicsBatchResultStore.loadTaxTriageRefs(from: tempDir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, ref)
    }

    func testCrossRefFilename() {
        let filename = MetagenomicsBatchResultStore.taxTriageRefFilename(runId: "taxtriage-20250325-143022")
        XCTAssertEqual(filename, "taxtriage-ref-taxtriage-20250325-143022.json")
    }

    func testMultipleCrossRefs() throws {
        let refA = TaxTriageCrossRef(
            resultDirectory: "/results/run1",
            runId: "run1",
            sampleId: "SampleA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            batchSampleCount: 2
        )

        let refB = TaxTriageCrossRef(
            resultDirectory: "/results/run2",
            runId: "run2",
            sampleId: "SampleB",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            batchSampleCount: 3
        )

        try MetagenomicsBatchResultStore.saveTaxTriageRef(refA, to: tempDir)
        try MetagenomicsBatchResultStore.saveTaxTriageRef(refB, to: tempDir)

        let loaded = MetagenomicsBatchResultStore.loadTaxTriageRefs(from: tempDir)
        XCTAssertEqual(loaded.count, 2)

        let runIds = Set(loaded.map(\.runId))
        XCTAssertTrue(runIds.contains("run1"))
        XCTAssertTrue(runIds.contains("run2"))
    }

    func testLoadFromEmptyDirectory() {
        let loaded = MetagenomicsBatchResultStore.loadTaxTriageRefs(from: tempDir)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testLoadFromNonExistentDirectory() {
        let bogus = tempDir.appendingPathComponent("does-not-exist")
        let loaded = MetagenomicsBatchResultStore.loadTaxTriageRefs(from: bogus)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCrossRefEquatable() {
        let ref1 = TaxTriageCrossRef(
            resultDirectory: "/results/run1",
            runId: "run1",
            sampleId: "SampleA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            batchSampleCount: 2
        )

        let ref2 = TaxTriageCrossRef(
            resultDirectory: "/results/run1",
            runId: "run1",
            sampleId: "SampleA",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            batchSampleCount: 2
        )

        let ref3 = TaxTriageCrossRef(
            resultDirectory: "/results/run1",
            runId: "run1",
            sampleId: "SampleB",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            batchSampleCount: 2
        )

        XCTAssertEqual(ref1, ref2)
        XCTAssertNotEqual(ref1, ref3)
    }
}
