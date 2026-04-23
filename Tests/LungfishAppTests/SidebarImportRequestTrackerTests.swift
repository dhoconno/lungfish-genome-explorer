// SidebarImportRequestTrackerTests.swift - Tests for sidebar import request completion accounting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class SidebarImportRequestTrackerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarImportRequestTrackerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testTrackerCompletesAfterExpandedFolderChildrenFinish() throws {
        let droppedFolder = tempDir.appendingPathComponent("expanded")
        let nestedFolder = droppedFolder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)

        let alphaURL = droppedFolder.appendingPathComponent("alpha.fa")
        let betaURL = nestedFolder.appendingPathComponent("beta.fa")
        try ">alpha\nACGT\n".write(to: alphaURL, atomically: true, encoding: .utf8)
        try ">beta\nTGCA\n".write(to: betaURL, atomically: true, encoding: .utf8)

        let plan = SidebarImportPlanner.makePlan(for: [droppedFolder])
        XCTAssertEqual(plan.sourceURLs, [alphaURL.standardizedFileURL, betaURL.standardizedFileURL])

        let tracker = SidebarImportRequestTracker(
            requestID: "request-1",
            trackedURLs: plan.sourceURLs
        )

        let firstUpdate = tracker.registerCompletion(
            requestID: "request-1",
            completedURL: alphaURL.standardizedFileURL,
            wasSuccessful: true
        )
        XCTAssertEqual(firstUpdate?.succeeded, 1)
        XCTAssertEqual(firstUpdate?.failed, 0)
        XCTAssertEqual(firstUpdate?.pendingCount, 1)
        XCTAssertEqual(firstUpdate?.isFinished, false)

        let secondUpdate = tracker.registerCompletion(
            requestID: "request-1",
            completedURL: betaURL.standardizedFileURL,
            wasSuccessful: true
        )
        XCTAssertEqual(secondUpdate?.succeeded, 2)
        XCTAssertEqual(secondUpdate?.failed, 0)
        XCTAssertEqual(secondUpdate?.pendingCount, 0)
        XCTAssertEqual(secondUpdate?.isFinished, true)
    }
}
