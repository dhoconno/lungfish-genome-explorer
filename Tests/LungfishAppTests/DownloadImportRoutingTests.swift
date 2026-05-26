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

    func testCopiedFASTQBundleIsNotQueuedForPostCopyIngestion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("barcode08.lungfishfastq", isDirectory: true)
        let chunksURL = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunksURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\nIIII\n".write(
            to: chunksURL.appendingPathComponent("chunk_0.fastq"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNil(DownloadImportRouting.postCopyFASTQIngestionTarget(
            importedURL: bundleURL,
            packagedFASTQPayloads: [:]
        ))
    }

    func testNewlyPackagedPlainFASTQIsQueuedForPostCopyIngestion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-routing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let payloadURL = bundleURL.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: payloadURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            DownloadImportRouting.postCopyFASTQIngestionTarget(
                importedURL: bundleURL,
                packagedFASTQPayloads: [DownloadImportRouting.canonicalPath(for: bundleURL): payloadURL]
            ),
            payloadURL
        )
    }
}
