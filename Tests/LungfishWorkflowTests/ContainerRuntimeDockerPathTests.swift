// ContainerRuntimeDockerPathTests.swift - The Docker check of the container factory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.11. `isDockerAvailable` ran `/usr/bin/which docker` and waited for it with no limit.
// It now searches the PATH string with no process. These cases pin a tool found, a tool absent and a
// file of the same name that is not executable.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class ContainerRuntimeDockerPathTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("docker-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func writeDocker(executable: Bool) throws {
        let url = scratch.appendingPathComponent("docker")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
    }

    func testADockerExecutableOnThePathIsFound() throws {
        try writeDocker(executable: true)

        XCTAssertTrue(NewContainerRuntimeFactory.isDockerCLIFound(inPath: "/nonexistent:\(scratch.path)"))
    }

    func testNoDockerOnThePathIsNotFound() {
        XCTAssertFalse(NewContainerRuntimeFactory.isDockerCLIFound(inPath: scratch.path))
    }

    func testADockerFileWithoutAnExecutePermissionIsNotFound() throws {
        try writeDocker(executable: false)

        XCTAssertFalse(NewContainerRuntimeFactory.isDockerCLIFound(inPath: scratch.path))
    }
}
