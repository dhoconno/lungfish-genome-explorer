// OperationCenterFailureLogTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishKit

/// A failed minimap2 run's log used to end at "Running minimap2..." and the
/// row's latest-line kept saying so; the "unknown option" error showed only
/// in the row subtitle. A failed operation's log must end with why it failed.
@MainActor
final class OperationCenterFailureLogTests: XCTestCase {
    private var center: OperationCenter!

    override func setUp() {
        super.setUp()
        center = OperationCenter()
    }

    override func tearDown() {
        center = nil
        super.tearDown()
    }

    private func item(_ id: UUID) throws -> OperationCenter.Item {
        try XCTUnwrap(center.items.first { $0.id == id })
    }

    func testFailureAppendsErrorMessageAndDetailToLog() throws {
        let id = center.start(title: "Map Reads (minimap2): S1", detail: "Mapping")
        center.log(id: id, level: .info, message: "Running minimap2...")

        XCTAssertTrue(center.fail(
            id: id,
            detail: "minimap2 failed",
            errorMessage: "minimap2 exited with status 1",
            errorDetail: "[E::main] unknown option: --bogus"
        ))

        let failed = try item(id)
        let messages = failed.logEntries.map(\.message)
        XCTAssertEqual(messages.first, "Running minimap2...")
        XCTAssertEqual(Array(messages.dropFirst()), [
            "Failed: minimap2 exited with status 1",
            "minimap2 failed",
            "[E::main] unknown option: --bogus",
        ])
        XCTAssertTrue(failed.logEntries.dropFirst().allSatisfy { $0.level == .error })
        XCTAssertEqual(failed.latestLogEntry?.message, "[E::main] unknown option: --bogus")
    }

    func testFailureWithOnlyDetailLogsIt() throws {
        let id = center.start(title: "Map Reads", detail: "Mapping")
        center.log(id: id, level: .info, message: "Running minimap2...")

        center.fail(id: id, detail: "minimap2: unknown option --bogus")

        let failed = try item(id)
        XCTAssertEqual(failed.latestLogEntry?.message, "Failed: minimap2: unknown option --bogus")
        XCTAssertEqual(failed.latestLogEntry?.level, .error)
        XCTAssertNotEqual(failed.latestLogEntry?.message, "Running minimap2...")
    }

    func testFailureDoesNotRepeatAnErrorTheWorkerAlreadyLogged() throws {
        let id = center.start(title: "EsViritu S1", detail: "Running")
        center.log(id: id, level: .error, message: "EsViritu exited 2")

        center.fail(id: id, detail: "EsViritu exited 2", errorMessage: "EsViritu exited 2")

        let messages = try item(id).logEntries.map(\.message)
        XCTAssertEqual(messages, ["EsViritu exited 2"])
    }

    func testCompletionAndCancellationDoNotAppendFailureLines() throws {
        let completed = center.start(title: "Done", detail: "Running")
        center.log(id: completed, level: .info, message: "step")
        center.complete(id: completed, detail: "All good")
        XCTAssertEqual(try item(completed).logEntries.map(\.message), ["step"])

        let cancelled = center.start(title: "Cancelled", detail: "Running")
        center.log(id: cancelled, level: .info, message: "step")
        center.acknowledgeCancellation(id: cancelled)
        XCTAssertEqual(try item(cancelled).logEntries.map(\.message), ["step"])
    }
}
