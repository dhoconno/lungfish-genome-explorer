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
        XCTAssertTrue(source.contains("try Task.checkCancellation()"))
        XCTAssertTrue(source.contains("var cancelled = false"))
        XCTAssertTrue(source.contains("state.cancelled = true"))
        XCTAssertTrue(source.contains("return state.cancelled"))
    }

    func testToolProvisionerDownloadIsCancellableAndProgressive() throws {
        let source = try workflowSource("Native/ToolProvisioning/ToolProvisioner.swift")

        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("URLSessionDownloadTask"))
        XCTAssertTrue(source.contains(".cancel()"))
        XCTAssertTrue(source.contains("didWriteData"))
        XCTAssertTrue(source.contains("resumeOnce"))
        XCTAssertTrue(source.contains("try Task.checkCancellation()"))
        XCTAssertTrue(source.contains("var cancelled = false"))
        XCTAssertTrue(source.contains("state.cancelled = true"))
        XCTAssertTrue(source.contains("return state.cancelled"))
    }

    func testManagedDatabaseDownloadsUseCancellationBox() throws {
        let paths = [
            "Databases/DatabaseRegistry.swift",
            "Metagenomics/MetagenomicsDatabaseRegistry.swift",
        ]

        for path in paths {
            let source = try workflowSource(path)
            XCTAssertTrue(source.contains("withTaskCancellationHandler"), path)
            XCTAssertTrue(source.contains("let taskBox = DownloadTaskCancellationBox()"), path)
            XCTAssertTrue(source.contains("taskBox.store(task)"), path)
            XCTAssertTrue(source.contains("taskBox.cancel()"), path)
            XCTAssertFalse(source.contains("nonisolated(unsafe) var downloadTask"), path)
        }
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
