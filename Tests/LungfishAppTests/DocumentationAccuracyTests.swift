// DocumentationAccuracyTests.swift - README and source-comment accuracy canaries
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class DocumentationAccuracyTests: XCTestCase {
    func testREADMEFormatAndCLISummariesMatchImplementedSupport() throws {
        let repositoryRoot = try Self.repositoryRoot()
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let lungfishIOSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/LungfishIO/LungfishIO.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("BBMap"))
        XCTAssertTrue(readme.contains("provision-tools"))
        XCTAssertFalse(readme.contains("GenBank, 2bit"))
        XCTAssertFalse(readme.contains("| Coverage    | BigWig, bedGraph"))
        XCTAssertTrue(readme.contains("BigWig detection only"))
        XCTAssertFalse(lungfishIOSource.contains("2bit (.2bit)"))
    }

    private static func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(domain: "DocumentationAccuracyTests", code: 1)
    }
}
