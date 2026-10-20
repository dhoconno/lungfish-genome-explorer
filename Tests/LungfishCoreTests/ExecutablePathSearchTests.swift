// ExecutablePathSearchTests.swift - The PATH search that replaced three `which` spawns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.11. The CLI locator, `debug env` and the Docker check found a tool by running
// `/usr/bin/which` and waiting for it. These cases pin the search that replaced the spawn: a tool found,
// a tool absent, and a file of the same name that is not executable.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

final class ExecutablePathSearchTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try TestTempDirectory.make(prefix: "path-search")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
        try super.tearDownWithError()
    }

    /// Makes a directory entry of a PATH string.
    private func makeDirectory(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ name: String, in directory: URL, executable: Bool) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }

    func testAnExecutableFileInAnEntryIsFound() throws {
        let bin = try makeDirectory("bin")
        let tool = try writeFile("sometool", in: bin, executable: true)

        XCTAssertEqual(ExecutablePathSearch.find("sometool", inPath: "/nonexistent:\(bin.path)")?.path, tool.path)
    }

    func testAToolThatIsNotOnThePathIsNotFound() throws {
        let bin = try makeDirectory("bin")
        try writeFile("othertool", in: bin, executable: true)

        XCTAssertNil(ExecutablePathSearch.find("sometool", inPath: bin.path))
    }

    func testAFileOfTheSameNameWithoutAnExecutePermissionIsNotFound() throws {
        let bin = try makeDirectory("bin")
        try writeFile("sometool", in: bin, executable: false)

        XCTAssertNil(ExecutablePathSearch.find("sometool", inPath: bin.path))
    }

    func testANonExecutableFileDoesNotShadowAnExecutableOneLaterOnThePath() throws {
        let first = try makeDirectory("first")
        let second = try makeDirectory("second")
        try writeFile("sometool", in: first, executable: false)
        let tool = try writeFile("sometool", in: second, executable: true)

        XCTAssertEqual(
            ExecutablePathSearch.find("sometool", inPath: "\(first.path):\(second.path)")?.path,
            tool.path
        )
    }

    func testADirectoryOfTheSameNameIsNotFound() throws {
        let bin = try makeDirectory("bin")
        try FileManager.default.createDirectory(
            at: bin.appendingPathComponent("sometool", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertNil(ExecutablePathSearch.find("sometool", inPath: bin.path))
    }

    func testTheFirstEntryThatHoldsTheToolWins() throws {
        let first = try makeDirectory("first")
        let second = try makeDirectory("second")
        let winner = try writeFile("sometool", in: first, executable: true)
        try writeFile("sometool", in: second, executable: true)

        XCTAssertEqual(
            ExecutablePathSearch.find("sometool", inPath: "\(first.path):\(second.path)")?.path,
            winner.path
        )
    }

    func testNoPathAnEmptyPathAnEmptyEntryAndANameWithASlashFindNothing() throws {
        let bin = try makeDirectory("bin")
        try writeFile("sometool", in: bin, executable: true)
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(bin.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }

        XCTAssertNil(ExecutablePathSearch.find("sometool", inPath: nil))
        XCTAssertNil(ExecutablePathSearch.find("sometool", inPath: ""))
        XCTAssertNil(ExecutablePathSearch.find("sometool", inPath: "::"), "an empty entry is not the current directory")
        XCTAssertNil(ExecutablePathSearch.find("../bin/sometool", inPath: bin.path))
        XCTAssertNil(ExecutablePathSearch.find("", inPath: bin.path))
    }
}
