// DbExtractCommandTests.swift - Tests for the conda db CLI commands (conda extract retired in 2.12 lane 12.11)
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

// MARK: - DbCommand Parsing Tests

/// Tests for `lungfish conda db` subcommand argument parsing.
final class DbCommandParsingTests: XCTestCase {

    /// Verifies that `db list` parses without arguments.
    func testDbListParsing() throws {
        let args = ["list"]
        let command = try DbCommand.parseAsRoot(args)
        XCTAssertTrue(command is DbCommand.DbListSubcommand)
    }

    /// Verifies that `db info <name>` parses the database name.
    func testDbInfoParsing() throws {
        let args = ["info", "Standard-8"]
        let command = try DbCommand.parseAsRoot(args)
        guard let info = command as? DbCommand.DbInfoSubcommand else {
            XCTFail("Expected DbInfoSubcommand")
            return
        }
        XCTAssertEqual(info.name, "Standard-8")
    }

    /// Verifies that `db download <name>` parses the database name.
    func testDbDownloadParsing() throws {
        let args = ["download", "Viral"]
        let command = try DbCommand.parseAsRoot(args)
        guard let download = command as? DbCommand.DbDownloadSubcommand else {
            XCTFail("Expected DbDownloadSubcommand")
            return
        }
        XCTAssertEqual(download.name, "Viral")
    }

    func testDbDownloadPreservesSpecialDatabaseName() throws {
        let command = try DbCommand.parseAsRoot(["download", "SILVA"])
        let download = try XCTUnwrap(command as? DbCommand.DbDownloadSubcommand)
        XCTAssertEqual(download.name, "SILVA")
    }

    /// Verifies that `db remove <name>` parses correctly.
    func testDbRemoveParsing() throws {
        let args = ["remove", "Standard-8"]
        let command = try DbCommand.parseAsRoot(args)
        guard let remove = command as? DbCommand.DbRemoveSubcommand else {
            XCTFail("Expected DbRemoveSubcommand")
            return
        }
        XCTAssertEqual(remove.name, "Standard-8")
        XCTAssertFalse(remove.deleteFiles)
    }

    /// Verifies that `db remove --delete-files <name>` sets the flag.
    func testDbRemoveWithDeleteFiles() throws {
        let args = ["remove", "--delete-files", "Viral"]
        let command = try DbCommand.parseAsRoot(args)
        guard let remove = command as? DbCommand.DbRemoveSubcommand else {
            XCTFail("Expected DbRemoveSubcommand")
            return
        }
        XCTAssertEqual(remove.name, "Viral")
        XCTAssertTrue(remove.deleteFiles)
    }

    /// Verifies that `db recommend` parses without arguments.
    func testDbRecommendParsing() throws {
        let args = ["recommend"]
        let command = try DbCommand.parseAsRoot(args)
        XCTAssertTrue(command is DbCommand.DbRecommendSubcommand)
    }
}
