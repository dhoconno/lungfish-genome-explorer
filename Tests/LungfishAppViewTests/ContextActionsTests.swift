// ContextActionsTests.swift - contextActions publishes its commands to accessibility
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import XCTest
@testable import LungfishApp

@MainActor
final class ContextActionsTests: XCTestCase {
    func testAccessibilityListsTheCommandsInMenuOrderWithoutDividers() {
        var performed: [String] = []
        let actions: [ContextAction] = [
            .command("Reveal in Finder") { performed.append("reveal") },
            .command("Quick Look") { performed.append("look") },
            .divider(),
            .command("Remove Attachment", role: .destructive) { performed.append("remove") },
        ]
        let commands = ContextAction.commands(in: actions)
        XCTAssertEqual(commands.map(\.title), ["Reveal in Finder", "Quick Look", "Remove Attachment"])
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count, "entries need distinct ids for ForEach")
        if case let .command(role, perform) = commands[2].kind {
            XCTAssertEqual(role, .destructive)
            perform()
        } else {
            XCTFail("expected a command")
        }
        XCTAssertEqual(performed, ["remove"])
    }

    func testDividersCarryDistinctIdsAndTheModifierBuilds() {
        let actions: [ContextAction] = [.command("A") {}, .divider("one"), .command("B") {}, .divider("two")]
        XCTAssertEqual(Set(actions.map(\.id)).count, 4)
        _ = Text("row").contextActions(actions)
    }
}
