// SystemTempScratchMarkerTests.swift - Scratch in the system temp folder names its creator
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S32 M2 item 1 (W1, W3, 2.10 P1). `ProjectTempDirectory.create(prefix:in: nil)`,
// which all ten `.systemOnly` sites reach, writes the `OwnedWorkDirectoryMarker` that project scratch
// gets. `TMPDIR` points the system temp folder at a folder under a TestTempDirectory root.

import Darwin
import Foundation
import LungfishTestSupport
@testable import LungfishIO
import XCTest

final class SystemTempScratchMarkerTests: XCTestCase {
    private var root: URL!
    /// Stands in for the system temp folder.
    private var systemTemp: URL!
    private var previousTMPDIR: String?

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "system-temp-scratch-marker").resolvingSymlinksInPath()
        systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(root)
    }

    func testScratchWithNoProjectCarriesTheMarkerThatNamesItsCreator() throws {
        let scratch = try ProjectTempDirectory.create(prefix: "taxtriage-", in: nil)

        XCTAssertEqual(scratch.deletingLastPathComponent().resolvingSymlinksInPath().path, systemTemp.path)
        XCTAssertTrue(scratch.lastPathComponent.hasPrefix("taxtriage-"), scratch.lastPathComponent)
        let marker = try OwnedWorkDirectoryMarkerStore.load(from: scratch, expectedProjectURL: systemTemp)
        XCTAssertTrue(marker.matchesProcessIdentity(try OwnedProcessIdentity.current()), "PID, start time and boot session")
        XCTAssertEqual(marker.state, .active)
        XCTAssertFalse(marker.keepIntermediates)
        XCTAssertEqual(marker.toolName, "ProjectTempDirectory")
    }

    /// The policy-aware entry the `.systemOnly` sites call adds its `TempOriginMarker` beside it.
    func testTheSystemOnlyPolicyMarksItsScratchAndKeepsItsOriginMarker() throws {
        let scratch = try ProjectTempDirectory.create(prefix: "nfcore-work-", contextURL: nil, policy: .systemOnly)

        XCTAssertNoThrow(try OwnedWorkDirectoryMarkerStore.load(from: scratch, expectedProjectURL: systemTemp))
        XCTAssertEqual(ProjectTempDirectory.readMarker(from: scratch)?.policy, .systemOnly)
        XCTAssertFalse(scratch.path.contains(" "), "the nf-core and TaxTriage callers refuse a path with a space")
    }

    /// The folder is the user's alone, as project scratch is.
    func testTheScratchIsOwnedByTheUserAndClosedToOthers() throws {
        let scratch = try ProjectTempDirectory.create(prefix: "variants-", in: nil)

        var info = stat()
        XCTAssertEqual(lstat(scratch.path, &info), 0)
        XCTAssertEqual(info.st_uid, getuid())
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(info.st_mode & 0o077, 0, "no group or other access")
    }
}
