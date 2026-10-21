// ManagedCompressionToolLockTests.swift - The lock names zstd and xz as managed tools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.17 M2. The sequence export runs zstd and the reference import runs zstd and xz. macOS ships
// neither, so the lock manifest, the single source of tool versions, holds both in its `tools` array (the array
// the required setup installs) and each has a NativeTool case that finds its executable in its own environment.

import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class ManagedCompressionToolLockTests: XCTestCase {
    private struct Row {
        let id: String
        let version: String
        let executable: String
        let tool: NativeTool
    }

    private let rows = [
        Row(id: "zstd", version: "1.5.7", executable: "zstd", tool: .zstd),
        Row(id: "xz", version: "5.8.3", executable: "xz", tool: .xz),
    ]

    func testTheLockNamesEachCompressorsIDVersionAndExecutable() throws {
        let lock = try ManagedToolLock.loadFromBundle()
        for row in rows {
            let entry = try XCTUnwrap(lock.entry(id: ManagedToolID(rawValue: row.id)), row.id)
            XCTAssertEqual(entry.source, .tool, "\(row.id) is in the tools array, which the required setup installs")
            XCTAssertEqual(entry.environment, row.id)
            XCTAssertEqual(entry.version, row.version)
            XCTAssertEqual(entry.executables, [row.executable])
            let spec = try XCTUnwrap(lock.tools.first { $0.id == row.id }?.packageSpec, row.id)
            XCTAssertTrue(spec.hasPrefix("conda-forge::\(row.id)=\(row.version)="), "\(row.id) pins its build: \(spec)")
        }
    }

    func testEachNativeToolFindsItsExecutableInItsOwnEnvironment() {
        for row in rows {
            XCTAssertEqual(row.tool.managedToolID.rawValue, row.id)
            XCTAssertEqual(row.tool.location, .managed(environment: row.id, executableName: row.executable))
            XCTAssertEqual(row.tool.versionArguments, ["--version"])
            XCTAssertFalse(row.tool.isBundled)
        }
    }
}
