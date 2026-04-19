// DownloadImportRoutingTests.swift - Tests for import routing of downloaded bundles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class DownloadImportRoutingTests: XCTestCase {
    func testDoesNotPreserveProjectTempBundlesInPlace() {
        let projectURL = URL(fileURLWithPath: "/tmp/Example Project.lungfish", isDirectory: true)
        let stagedBundle = projectURL
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("batch-123", isDirectory: true)
            .appendingPathComponent("NC_045512.lungfishref", isDirectory: true)

        XCTAssertFalse(
            DownloadImportRouting.shouldPreserveInPlace(
                downloadedURL: stagedBundle,
                projectURL: projectURL,
                workingDirectoryURL: nil
            )
        )
    }

    func testPreservesVisibleProjectBundlesInPlace() {
        let projectURL = URL(fileURLWithPath: "/tmp/example.lungfish", isDirectory: true)
        let extractionBundle = projectURL
            .appendingPathComponent("Extractions", isDirectory: true)
            .appendingPathComponent("materialized-inputs-123", isDirectory: true)

        XCTAssertTrue(
            DownloadImportRouting.shouldPreserveInPlace(
                downloadedURL: extractionBundle,
                projectURL: projectURL,
                workingDirectoryURL: nil
            )
        )
    }

    func testPreservesBundlesInsideWorkingDirectory() {
        let workingDirectory = URL(fileURLWithPath: "/tmp/lungfish-working", isDirectory: true)
        let bundleURL = workingDirectory
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)

        XCTAssertTrue(
            DownloadImportRouting.shouldPreserveInPlace(
                downloadedURL: bundleURL,
                projectURL: nil,
                workingDirectoryURL: workingDirectory
            )
        )
    }
}
