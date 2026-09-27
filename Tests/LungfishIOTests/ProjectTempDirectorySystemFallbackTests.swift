// ProjectTempDirectorySystemFallbackTests.swift - TMPDIR handling for project-less scratch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class ProjectTempDirectorySystemFallbackTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectTempTMPDIR-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// `FileManager.temporaryDirectory` ignores `TMPDIR`; the system fallback
    /// must not, so `variants call` and the other `.systemOnly` callers put
    /// their workspace where the user pointed.
    func testSystemTemporaryDirectoryHonoursTMPDIR() {
        let resolved = ProjectTempDirectory.systemTemporaryDirectory(environment: ["TMPDIR": scratch.path])
        XCTAssertEqual(resolved.standardizedFileURL.path, scratch.standardizedFileURL.path)
    }

    func testUnsetOrUnusableTMPDIRFallsBackToThePerUserDirectory() {
        let perUser = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertEqual(
            ProjectTempDirectory.systemTemporaryDirectory(environment: [:]).standardizedFileURL.path,
            perUser
        )
        XCTAssertEqual(
            ProjectTempDirectory.systemTemporaryDirectory(environment: ["TMPDIR": "   "]).standardizedFileURL.path,
            perUser
        )
        let missing = scratch.appendingPathComponent("does-not-exist", isDirectory: true).path
        XCTAssertEqual(
            ProjectTempDirectory.systemTemporaryDirectory(environment: ["TMPDIR": missing]).standardizedFileURL.path,
            perUser
        )
    }

    /// The `.systemOnly` policy (what `variants call` uses for its staging
    /// root) creates the directory under `TMPDIR` when it is set.
    func testSystemOnlyPolicyCreatesUnderTMPDIR() throws {
        let previous = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", scratch.path, 1)
        defer {
            if let previous { setenv("TMPDIR", previous, 1) } else { unsetenv("TMPDIR") }
        }

        let created = try ProjectTempDirectory.create(prefix: "variants-", contextURL: nil, policy: .systemOnly)
        defer { try? FileManager.default.removeItem(at: created) }
        XCTAssertTrue(
            created.standardizedFileURL.path.hasPrefix(scratch.standardizedFileURL.path + "/"),
            "\(created.path) must be under TMPDIR \(scratch.path)"
        )
        XCTAssertTrue(created.lastPathComponent.hasPrefix("variants-"))
    }
}
