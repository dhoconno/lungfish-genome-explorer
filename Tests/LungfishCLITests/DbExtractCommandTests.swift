// DbExtractCommandTests.swift - Tests for db and extract CLI commands
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

// MARK: - ExtractSubcommand Parsing Tests

/// Tests for `lungfish conda extract` argument parsing.
final class ExtractSubcommandParsingTests: XCTestCase {

    /// Verifies basic single-file extraction argument parsing.
    func testBasicExtractParsing() throws {
        let args = [
            "--kraken-output", "class.kraken",
            "--source", "reads.fastq",
            "--output", "extracted.fastq",
            "--taxid", "562",
        ]
        let command = try ExtractSubcommand.parse(args)
        XCTAssertEqual(command.krakenOutput, "class.kraken")
        XCTAssertEqual(command.sourceFiles, ["reads.fastq"])
        XCTAssertEqual(command.outputFiles, ["extracted.fastq"])
        XCTAssertEqual(command.taxIds, ["562"])
        XCTAssertFalse(command.includeChildren)
        XCTAssertNil(command.kreportFile)
    }

    /// Verifies paired-end extraction argument parsing.
    func testPairedEndExtractParsing() throws {
        let args = [
            "--kraken-output", "class.kraken",
            "--source", "R1.fastq",
            "--source", "R2.fastq",
            "--output", "R1_out.fastq",
            "--output", "R2_out.fastq",
            "--taxid", "562",
        ]
        let command = try ExtractSubcommand.parse(args)
        XCTAssertEqual(command.sourceFiles, ["R1.fastq", "R2.fastq"])
        XCTAssertEqual(command.outputFiles, ["R1_out.fastq", "R2_out.fastq"])
    }

    /// Verifies that --include-children requires --kreport (parse fails validation).
    func testIncludeChildrenValidation() {
        let args = [
            "--kraken-output", "class.kraken",
            "--source", "reads.fastq",
            "--output", "out.fastq",
            "--taxid", "562",
            "--include-children",
        ]

        // parse() calls validate() automatically, so this should throw
        XCTAssertThrowsError(try ExtractSubcommand.parse(args)) { error in
            let desc = "\(error)"
            XCTAssertTrue(desc.contains("kreport"),
                          "Error should mention --kreport: \(desc)")
        }
    }

    /// Verifies that --include-children with --kreport passes validation.
    func testIncludeChildrenWithKreport() throws {
        let args = [
            "--kraken-output", "class.kraken",
            "--source", "reads.fastq",
            "--output", "out.fastq",
            "--taxid", "562",
            "--include-children",
            "--kreport", "class.kreport",
        ]
        let command = try ExtractSubcommand.parse(args)
        XCTAssertTrue(command.includeChildren)
        XCTAssertEqual(command.kreportFile, "class.kreport")
    }

    /// Verifies that comma-separated tax IDs are accepted.
    func testCommaSeparatedTaxIds() throws {
        let args = [
            "--kraken-output", "class.kraken",
            "--source", "reads.fastq",
            "--output", "out.fastq",
            "--taxid", "562,1280,9606",
        ]
        let command = try ExtractSubcommand.parse(args)
        XCTAssertEqual(command.taxIds, ["562,1280,9606"])
    }

    /// Verifies that mismatched source/output counts fail validation during parse.
    func testMismatchedSourceOutputValidation() {
        let args = [
            "--kraken-output", "class.kraken",
            "--source", "R1.fastq",
            "--source", "R2.fastq",
            "--output", "out.fastq",
            "--taxid", "562",
        ]

        // parse() calls validate() automatically, so this should throw
        XCTAssertThrowsError(try ExtractSubcommand.parse(args)) { error in
            let desc = "\(error)"
            XCTAssertTrue(desc.contains("source") || desc.contains("output"),
                          "Error should mention source/output mismatch: \(desc)")
        }
    }
}
