// AlignmentDuplicateServiceTests.swift - Tests for duplicate workflow helpers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class AlignmentDuplicateServiceTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlignmentDuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testUniqueDeduplicatedBundleURLUsesDefaultSuffixWhenAvailable() {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(for: source)
        XCTAssertEqual(candidate.lastPathComponent, "example-deduplicated.lungfishref")
    }

    func testUniqueDeduplicatedBundleURLAdvancesSuffixWhenExistingPathPresent() throws {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let existing = tempDir.appendingPathComponent("example-deduplicated.lungfishref")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(for: source)
        XCTAssertEqual(candidate.lastPathComponent, "example-deduplicated-2.lungfishref")
    }

    func testUniqueDeduplicatedBundleURLPrefersExplicitOutputWhenUnused() {
        let source = tempDir.appendingPathComponent("example.lungfishref")
        let preferred = tempDir.appendingPathComponent("custom-output.lungfishref")
        let candidate = AlignmentDuplicateService.uniqueDeduplicatedBundleURL(
            for: source,
            preferred: preferred
        )
        XCTAssertEqual(candidate, preferred)
    }

    func testAlignmentDuplicateErrorDescriptionsAreNonEmpty() {
        let errors: [AlignmentDuplicateError] = [
            .noAlignmentTracks,
            .sourcePathNotFound("/tmp/missing.bam"),
            .samtoolsFailed("mock failure")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }
}
