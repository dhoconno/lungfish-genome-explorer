// NCBIDownloadCancellationSourceTests.swift - source regression for NCBI delegate downloads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class NCBIDownloadCancellationSourceTests: XCTestCase {
    func testGenomeFileDownloadsBridgeTaskCancellationToURLSessionTask() throws {
        // The download-cancellation machinery lives across two files: the actor's
        // download methods (NCBIService.swift) drive the cancellation handler and
        // task, while the ContinuationDownloadDelegate implementation (moved into
        // NCBIDownloadDelegate.swift) owns the resume-once bridging. Scan the
        // combined source so this regression test is independent of that split.
        let root = repositoryRoot().appendingPathComponent("Sources/LungfishCore/Services/NCBI")
        let service = try String(
            contentsOf: root.appendingPathComponent("NCBIService.swift"),
            encoding: .utf8
        )
        let delegate = try String(
            contentsOf: root.appendingPathComponent("NCBIDownloadDelegate.swift"),
            encoding: .utf8
        )
        let source = service + "\n" + delegate

        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("URLSessionDownloadTask"))
        XCTAssertTrue(source.contains(".cancel()"))
        XCTAssertTrue(source.contains("ContinuationDownloadDelegate"))
        XCTAssertTrue(source.contains("resumeOnce"))
        XCTAssertTrue(source.contains("try Task.checkCancellation()"))
        XCTAssertTrue(source.contains("var cancelled = false"))
        XCTAssertTrue(source.contains("state.cancelled = true"))
        XCTAssertTrue(source.contains("return state.cancelled"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
