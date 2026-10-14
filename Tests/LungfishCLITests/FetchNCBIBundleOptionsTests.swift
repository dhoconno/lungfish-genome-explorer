// FetchNCBIBundleOptionsTests.swift - The options of lungfish-cli fetch ncbi --bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

/// `fetch ncbi --bundle` (Phase 2.10 lane A45) builds one `.lungfishref` bundle for each accession,
/// as the NCBI browser's nucleotide and virus rows do. These tests pin what the leaf accepts and
/// refuses before any folder exists. A refusal throws from `validate()`, so ArgumentParser's
/// `parse` rejects it.
final class FetchNCBIBundleOptionsTests: XCTestCase {
    func testBundleTakesAccessionsAnOutputFolderAndEvents() throws {
        let command = try NCBISubcommand.parse([
            "MN908947.3", "NC_045512.2", "--bundle", "--output-dir", "/p/Project.lungfish/Downloads", "--format", "json",
        ])
        XCTAssertTrue(command.bundle)
        XCTAssertEqual(command.accessions, ["MN908947.3", "NC_045512.2"])
        XCTAssertEqual(command.outputDir, "/p/Project.lungfish/Downloads")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertFalse(command.noGFF3)
    }

    func testNoGFF3TurnsTheAnnotationDownloadOff() throws {
        let command = try NCBISubcommand.parse(["MN908947.3", "--bundle", "--no-gff3"])
        XCTAssertTrue(command.noGFF3)
        XCTAssertNil(command.outputDir, "the folder defaults to the current one when the run starts")
    }

    func testThePlainLeafKeepsItsFlagsAndDefaults() throws {
        let command = try NCBISubcommand.parse(["MN908947.3", "--save-to", "x.gb"])
        XCTAssertFalse(command.bundle)
        XCTAssertEqual(command.saveTo, "x.gb")
        XCTAssertEqual(command.fetchFormat, "genbank")
    }

    func testBundleRefusesWhatOnlyTheFileModeMeans() {
        for arguments in [
            ["MN908947.3", "--bundle", "--save-to", "x.gb"],
            ["MN908947.3", "--bundle", "--fetch-format", "fasta"],
            ["MN908947.3", "--bundle", "--db", "protein"],
        ] {
            XCTAssertThrowsError(try NCBISubcommand.parse(arguments), "\(arguments)")
        }
    }

    func testTheBundleOptionsNeedTheBundleFlag() {
        for arguments in [
            ["MN908947.3", "--output-dir", "/p"],
            ["MN908947.3", "--no-gff3"],
        ] {
            XCTAssertThrowsError(try NCBISubcommand.parse(arguments), "\(arguments)")
        }
    }

    /// Under `--format json` the leaf prints events on standard output. A plain run without
    /// `--save-to` would print its records there too, so it refuses before it fetches anything
    /// (A45 M1 ruling, section 2). The bundle mode writes into its folder and needs no file.
    func testPlainEventsNeedSaveTo() throws {
        XCTAssertThrowsError(try NCBISubcommand.parse(["MN908947.3", "--format", "json"]))
        let command = try NCBISubcommand.parse(["MN908947.3", "--save-to", "x.gb", "--format", "json"])
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertNoThrow(try NCBISubcommand.parse(["MN908947.3", "--bundle", "--format", "json"]))
        XCTAssertNoThrow(try NCBISubcommand.parse(["MN908947.3"]), "text mode still prints the records")
    }

    /// The NCBI key reaches the leaf through the environment. The option stays for a person at a
    /// terminal, and the app never passes it.
    func testTheKeyOptionStillParsesWithBundle() throws {
        let command = try NCBISubcommand.parse(["MN908947.3", "--bundle", "--api-key", "lge-test-not-a-key"])
        XCTAssertEqual(command.apiKey, "lge-test-not-a-key")
    }
}
