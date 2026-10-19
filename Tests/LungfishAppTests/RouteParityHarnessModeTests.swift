// RouteParityHarnessModeTests.swift - The parity harness compares the modes of the files two routes wrote
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.23 M2 (RECORD-MODE, QA 2). `OutputEquivalence` compares content only, so a route that wrote its
// records 0600 passed every parity class while the other route's read 0644. The harness now reports one difference for
// each file both roots hold whose permission bits differ, and these cases test that comparison itself.

import Foundation
import LungfishKitTestSupport
import LungfishTestSupport
import XCTest

final class RouteParityHarnessModeTests: XCTestCase {
    private var scratch: URL!
    private let harness = RouteParityHarness(cliBinary: URL(fileURLWithPath: "/nonexistent/lungfish-cli"), kind: .bundle)

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = try TestTempDirectory.make(prefix: "parity-mode")
    }

    override func tearDownWithError() throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
        try super.tearDownWithError()
    }

    /// A side root that holds `record.json` with the same bytes on every side and the mode the side wrote it with.
    private func side(_ side: RouteParitySide, wrote mode: Int) throws -> RouteParitySideRun {
        let root = scratch.appendingPathComponent(side.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("record.json")
        try Data("{\"same\":true}\n".utf8).write(to: record)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: record.path)
        return RouteParitySideRun(side: side, root: root, outcome: RouteParitySideOutcome(end: .completed))
    }

    func testTwoRoutesThatWriteDifferentModesFailTheComparison() throws {
        let found = try harness.differences(try side(.a, wrote: 0o644), try side(.c, wrote: 0o600))
        XCTAssertEqual(found.map(\.id), ["mode: record.json"])
        XCTAssertEqual(found.first?.detail, "A 0644, C 0600")
    }

    func testTwoRoutesThatWriteTheSameModeDoNotDiffer() throws {
        let found = try harness.differences(try side(.a, wrote: 0o600), try side(.c, wrote: 0o600))
        XCTAssertEqual(found.map(\.id), [])
    }
}
