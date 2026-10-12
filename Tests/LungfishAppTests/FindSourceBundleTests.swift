// FindSourceBundleTests.swift - Regression tests for MappingResultLayoutService.findSourceBundle
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The window code (the Map Reads completion and the end of a TaxTriage run) finds the source bundle
// of its inputs through the Workflow finder, the one `lungfish-cli map` uses. The App's own copy went
// with the in-process classifier launch in Phase 2.9 (E14).

import XCTest
import LungfishWorkflow

final class FindSourceBundleTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-find-bundle-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // Normalize URLs for comparison: deletingLastPathComponent() may add a trailing
    // slash that appendingPathComponent() does not, so compare using standardizedFileURL.
    private func assertURLEqual(_ lhs: URL?, _ rhs: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            lhs?.standardizedFileURL.path,
            rhs.standardizedFileURL.path,
            file: file, line: line
        )
    }

    func testFindsWhenInputIsBundleURL() {
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq")
        let result = MappingResultLayoutService.findSourceBundle(for: [bundleURL])
        assertURLEqual(result, bundleURL)
    }

    func testFindsWhenInputIsFileInsideBundle() {
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq")
        let fileURL = bundleURL.appendingPathComponent("reads.fastq.gz")
        let result = MappingResultLayoutService.findSourceBundle(for: [fileURL])
        assertURLEqual(result, bundleURL)
    }

    func testReturnsNilForPlainFASTQ() {
        let fileURL = tempDir.appendingPathComponent("reads.fastq.gz")
        let result = MappingResultLayoutService.findSourceBundle(for: [fileURL])
        XCTAssertNil(result)
    }

    func testReturnsNilForEmptyArray() {
        let result = MappingResultLayoutService.findSourceBundle(for: [])
        XCTAssertNil(result)
    }

    func testFindsFirstBundleInMultipleInputs() {
        let plainFile = tempDir.appendingPathComponent("other.fastq")
        let bundleURL = tempDir.appendingPathComponent("sample.lungfishfastq")
        let fileInBundle = bundleURL.appendingPathComponent("reads.fastq.gz")
        let result = MappingResultLayoutService.findSourceBundle(for: [plainFile, fileInBundle])
        assertURLEqual(result, bundleURL)
    }

    func testCaseInsensitiveExtension() {
        let bundleURL = tempDir.appendingPathComponent("sample.LUNGFISHFASTQ")
        let result = MappingResultLayoutService.findSourceBundle(for: [bundleURL])
        assertURLEqual(result, bundleURL)
    }

    func testFileInsideBundleWithMixedCaseExtension() {
        let bundleURL = tempDir.appendingPathComponent("sample.LungfishFastq")
        let fileURL = bundleURL.appendingPathComponent("reads.fastq")
        let result = MappingResultLayoutService.findSourceBundle(for: [fileURL])
        assertURLEqual(result, bundleURL)
    }
}
