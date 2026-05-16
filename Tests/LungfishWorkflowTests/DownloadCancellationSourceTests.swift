// DownloadCancellationSourceTests.swift - source regressions for workflow downloads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class DownloadCancellationSourceTests: XCTestCase {
    func testEsVirituDatabaseDownloadIsCancellableAndProgressive() throws {
        let source = try workflowSource("Metagenomics/EsVirituDatabaseManager.swift")

        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("URLSessionDownloadTask"))
        XCTAssertTrue(source.contains(".cancel()"))
        XCTAssertTrue(source.contains("didWriteData"))
        XCTAssertTrue(source.contains("resumeOnce"))
    }

    func testToolProvisionerDownloadIsCancellableAndProgressive() throws {
        let source = try workflowSource("Native/ToolProvisioning/ToolProvisioner.swift")

        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("URLSessionDownloadTask"))
        XCTAssertTrue(source.contains(".cancel()"))
        XCTAssertTrue(source.contains("didWriteData"))
        XCTAssertTrue(source.contains("resumeOnce"))
    }

    private func workflowSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishWorkflow")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
