// SystemTempScratchLaunchSweepTests.swift - The launch sweep runs off the main actor on the root it is given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S32 M2 item 3 (decision S3). The app starts the system temp scratch sweep once per
// launch, detached at utility priority, and its root is a parameter, so these tests sweep a
// TestTempDirectory folder and never the real system temp folder.

import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishApp
import XCTest

final class SystemTempScratchLaunchSweepTests: XCTestCase {

    /// Where the sweep ran, recorded from the detached task.
    private final class SweepSite: @unchecked Sendable {
        private let lock = NSLock()
        private var sweptRoot: URL?
        private var ranOnMainThread: Bool?

        func record(root: URL) {
            lock.withLock {
                sweptRoot = root
                ranOnMainThread = pthread_main_np() != 0
            }
        }

        var root: URL? { lock.withLock { sweptRoot } }
        var onMainThread: Bool? { lock.withLock { ranOnMainThread } }
    }

    @MainActor
    func testTheLaunchSweepRunsOffTheMainActorAndRemovesScratchWhoseCreatorIsGone() async throws {
        let root = try TestTempDirectory.make(prefix: "launch-scratch-sweep").resolvingSymlinksInPath()
        defer { TestTempDirectory.cleanup(root) }
        let current = try OwnedProcessIdentity.current()
        let reusedPID = OwnedProcessIdentity(
            processIdentifier: current.processIdentifier,
            processStartTime: current.processStartTime &+ 1,
            bootSessionID: current.bootSessionID
        )
        let abandoned = try Self.makeScratch(in: root, prefix: "taxtriage-", creator: reusedPID)
        let live = try Self.makeScratch(in: root, prefix: "nfcore-work-", creator: current)
        let site = SweepSite()

        let outcome = await AppDelegate.startSystemTempScratchSweep(root: root) { sweptRoot in
            site.record(root: sweptRoot)
            return SystemTempScratchSweep.sweep(root: sweptRoot)
        }.value

        XCTAssertEqual(site.root, root, "the sweep runs on the root it is given")
        XCTAssertEqual(site.onMainThread, false, "the sweep never runs on the main thread")
        XCTAssertEqual(outcome.removed.map(\.lastPathComponent), [abandoned.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a live creator's scratch stays")
    }

    /// With no root the sweep reads the system temp folder, which honours `TMPDIR`. The stand-in sweep
    /// removes nothing.
    func testTheLaunchSweepDefaultsToTheSystemTempFolder() async {
        let site = SweepSite()

        _ = await AppDelegate.startSystemTempScratchSweep { sweptRoot in
            site.record(root: sweptRoot)
            return SystemTempScratchSweep.Outcome()
        }.value

        XCTAssertEqual(site.root?.standardizedFileURL, ProjectTempDirectory.systemTemporaryDirectory().standardizedFileURL)
        XCTAssertEqual(site.onMainThread, false)
    }

    private static func makeScratch(in root: URL, prefix: String, creator: OwnedProcessIdentity) throws -> URL {
        try OwnedWorkDirectoryMarkerStore.createDirectory(
            OwnedWorkDirectoryCreationRequest(
                projectURL: root,
                parentDirectoryURL: root,
                prefix: prefix,
                runID: UUID(),
                processIdentity: creator,
                state: .active,
                lockRelativePath: nil,
                keepIntermediates: false,
                toolName: "ProjectTempDirectory",
                toolVersion: "test"
            )
        )
    }
}
