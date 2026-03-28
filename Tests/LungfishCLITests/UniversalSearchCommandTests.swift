// UniversalSearchCommandTests.swift - Parsing and registration tests for universal-search CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class UniversalSearchCommandTests: XCTestCase {

    func testUniversalSearchParsingDefaults() throws {
        let cmd = try UniversalSearchCommand.parse([
            "/tmp/project.lungfish",
        ])

        XCTAssertEqual(cmd.projectPath, "/tmp/project.lungfish")
        XCTAssertEqual(cmd.query, "")
        XCTAssertEqual(cmd.limit, 200)
        XCTAssertFalse(cmd.reindex)
        XCTAssertFalse(cmd.stats)
    }

    func testUniversalSearchParsingCustomOptions() throws {
        let cmd = try UniversalSearchCommand.parse([
            "/tmp/project.lungfish",
            "--query", "virus:hku1 type:classification_result",
            "--limit", "75",
            "--reindex",
            "--stats",
        ])

        XCTAssertEqual(cmd.projectPath, "/tmp/project.lungfish")
        XCTAssertEqual(cmd.query, "virus:hku1 type:classification_result")
        XCTAssertEqual(cmd.limit, 75)
        XCTAssertTrue(cmd.reindex)
        XCTAssertTrue(cmd.stats)
    }

    func testUniversalSearchRegisteredAtRoot() {
        let subcommands = LungfishCLI.configuration.subcommands
        let names = subcommands.compactMap {
            ($0 as? any ParsableCommand.Type)?.configuration.commandName
        }

        XCTAssertTrue(
            names.contains("universal-search"),
            "LungfishCLI should include universal-search subcommand"
        )
    }
}

