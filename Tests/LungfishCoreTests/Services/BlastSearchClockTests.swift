// BlastSearchClockTests.swift - The clock a BLAST search runs on, by hand, scaled and from the environment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane BLASTNET, N1 (ARCH-BLAST-RESILIENCE section 7).

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishCore

final class BlastSearchClockTests: XCTestCase {
    private var folder: URL!

    private var scaledEnvironment: [String: String] {
        [
            BlastServiceEndpoints.standInOriginVariable: "http://127.0.0.1:9",
            BlastStandInState.stateVariable: folder.path,
            BlastStandInState.timeScaleVariable: "600",
        ]
    }

    private var anchorFile: URL {
        folder.appendingPathComponent(BlastStandInState.clockAnchorFileName)
    }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-search-clock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAScaledClockReadsFastAndSleepsShort() async throws {
        let hand = BlastHandClock(advancesBySleeping: true)
        let anchor = hand.now.addingTimeInterval(-10)
        let scaled = BlastSearchClock.scaled(600, anchor: anchor, base: hand.clock)
        XCTAssertEqual(scaled.now().timeIntervalSince(anchor), 6000, accuracy: 0.001, "10 s on the base reads as 6000 s")

        try await scaled.sleep(180)

        XCTAssertEqual(hand.sleeps.count, 1)
        XCTAssertEqual(hand.sleeps[0], 0.3, accuracy: 0.000_1, "180 s at 600 times speed is 0.3 s")
        XCTAssertEqual(scaled.now().timeIntervalSince(anchor), 6180, accuracy: 0.001)
    }

    func testTheEnvironmentNamesAScaledClockOnlyWithAStandIn() throws {
        _ = BlastStandInState.clockAnchor(in: folder)
        let hourAgo = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: anchorFile.path)
        let scaled = BlastSearchClock(environment: scaledEnvironment, sharedFolder: folder)
        XCTAssertGreaterThan(scaled.now().timeIntervalSince(Date()), 3600, "an hour past the anchor reads as 600 hours")

        var noOrigin = scaledEnvironment
        noOrigin[BlastServiceEndpoints.standInOriginVariable] = nil
        let empty = folder.appendingPathComponent("no-origin", isDirectory: true)
        let system = BlastSearchClock(environment: noOrigin, sharedFolder: empty)
        XCTAssertLessThan(abs(system.now().timeIntervalSince(Date())), 30, "with no stand-in the scale is not read")
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "and nothing is written")
    }

    /// The second process must read the time of the first, since due times saved by one are read by the other.
    func testTwoClocksInOneFolderReadOneAnchor() throws {
        let first = BlastStandInState.clockAnchor(in: folder)
        let dated = Date().addingTimeInterval(-500)
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: anchorFile.path)
        let second = BlastStandInState.clockAnchor(in: folder)

        XCTAssertLessThan(first.timeIntervalSince(Date()), 30)
        XCTAssertLessThan(abs(second.timeIntervalSince(dated)), 1, "a later reader takes the date already there")
        XCTAssertEqual(try Data(contentsOf: anchorFile).count, 0, "the anchor holds no bytes to read half written")
    }

    func testATimeScaleThatIsNotAPositiveNumberReadsAsTheWallClock() throws {
        for value in ["0", "-5", "fast", "inf", "nan", ""] {
            var environment = scaledEnvironment
            environment[BlastStandInState.timeScaleVariable] = value
            XCTAssertEqual(try XCTUnwrap(BlastStandInState(environment: environment)).timeScale, 1, value)
        }
        XCTAssertEqual(try XCTUnwrap(BlastStandInState(environment: scaledEnvironment)).timeScale, 600)
    }

    func testAHandClockSleepHoldsUntilTheClockPassesIt() async throws {
        let hand = BlastHandClock()
        let clock = hand.clock
        let sleeping = Task { try await clock.sleep(60) }
        let started = await waitUntil(budget: .lookup) { hand.pendingSleeps == 1 }
        XCTAssertTrue(started)

        hand.advance(by: 59)
        XCTAssertEqual(hand.pendingSleeps, 1, "59 s does not end a 60 s sleep")
        hand.advance(by: 1)
        try await sleeping.value

        XCTAssertEqual(hand.pendingSleeps, 0)
        XCTAssertEqual(hand.sleeps, [60])
    }

    func testAHandClockSleepEndsWhenItsTaskIsCancelled() async throws {
        let hand = BlastHandClock()
        let clock = hand.clock
        let sleeping = Task { try await clock.sleep(60) }
        let started = await waitUntil(budget: .lookup) { hand.pendingSleeps == 1 }
        XCTAssertTrue(started)

        sleeping.cancel()

        do {
            try await sleeping.value
            XCTFail("a cancelled sleep throws")
        } catch is CancellationError {
            XCTAssertEqual(hand.pendingSleeps, 0)
        }
    }
}
