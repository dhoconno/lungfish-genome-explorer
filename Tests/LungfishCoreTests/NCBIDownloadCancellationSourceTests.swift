// NCBIDownloadCancellationSourceTests.swift - source regression for NCBI delegate downloads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class NCBIDownloadCancellationSourceTests: XCTestCase {
    func testGenomeFileDownloadsBridgeTaskCancellationToURLSessionTask() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishCore/Services/NCBI/NCBIService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("URLSessionDownloadTask"))
        XCTAssertTrue(source.contains(".cancel()"))
        XCTAssertTrue(source.contains("ContinuationDownloadDelegate"))
        XCTAssertTrue(source.contains("resumeOnce"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
