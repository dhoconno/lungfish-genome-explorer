// FetchPathoplexusOptionsTests.swift - The options of lungfish-cli fetch pathoplexus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

/// `fetch pathoplexus` (Phase 2.10 lane A45 M2) builds one `.lungfishref` bundle for each Pathoplexus
/// accession, as the Pathoplexus browser's rows do. These tests pin what the leaf accepts and refuses
/// before any folder exists. A refusal throws from `validate()` or from the parser, so ArgumentParser's
/// `parse` rejects it.
final class FetchPathoplexusOptionsTests: XCTestCase {
    func testTheLeafTakesAccessionsAnOrganismAnOutputFolderAndEvents() throws {
        let command = try PathoplexusSubcommand.parse([
            "PP_0012345", "PP_0012346", "--organism", "mpox", "--output-dir", "/p/Project.lungfish/Downloads", "--format", "json",
        ])
        XCTAssertEqual(command.accessions, ["PP_0012345", "PP_0012346"])
        XCTAssertEqual(command.organism, "mpox")
        XCTAssertEqual(command.outputDir, "/p/Project.lungfish/Downloads")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertFalse(command.noGFF3)
    }

    func testNoGFF3TurnsTheAnnotationDownloadOff() throws {
        let command = try PathoplexusSubcommand.parse(["PP_0012345", "--organism", "mpox", "--no-gff3"])
        XCTAssertTrue(command.noGFF3)
        XCTAssertNil(command.outputDir, "the folder defaults to the current one when the run starts")
    }

    /// Accessions are not organism-scoped, so the organism names the LAPIS the record is read from.
    func testTheOrganismIsRequiredAndMayNotBeBlank() {
        XCTAssertThrowsError(try PathoplexusSubcommand.parse(["PP_0012345"]))
        XCTAssertThrowsError(try PathoplexusSubcommand.parse(["PP_0012345", "--organism", "  "]))
        XCTAssertThrowsError(try PathoplexusSubcommand.parse(["--organism", "mpox"]), "an accession is required")
    }

    /// The NCBI key reaches the leaf through the environment. The option stays for a person at a
    /// terminal, and the app never passes it. Pathoplexus takes no key, so the leaf has no other.
    func testTheNCBIKeyOptionParsesAndPathoplexusTakesNone() throws {
        let command = try PathoplexusSubcommand.parse(["PP_0012345", "--organism", "mpox", "--api-key", "lge-test-not-a-key"])
        XCTAssertEqual(command.apiKey, "lge-test-not-a-key")
        XCTAssertThrowsError(try PathoplexusSubcommand.parse(["PP_0012345", "--organism", "mpox", "--pathoplexus-token", "x"]))
    }

    /// The request names the command that fetches one accession, with the key left out.
    func testTheRequestNamesTheCommandForOneAccessionWithoutTheKey() throws {
        let command = try PathoplexusSubcommand.parse([
            "PP_0012345", "PP_0012346", "--organism", "mpox", "--output-dir", "/p/out", "--no-gff3",
            "--api-key", "lge-test-not-a-key", "--format", "json",
        ])
        let replay = FetchPathoplexusRequest(command: command).command(for: "PP_0012346")
        XCTAssertEqual(
            Array(replay.dropFirst()),
            ["fetch", "pathoplexus", "PP_0012346", "--organism", "mpox", "--output-dir", "/p/out", "--no-gff3",
             "--api-key", "<redacted>", "--format", "json"])
        XCTAssertFalse(replay.contains("lge-test-not-a-key"))
    }

    /// `fetch` has `ncbi` as its default leaf, so an unregistered `pathoplexus` would parse as an NCBI
    /// accession. The leaf is a subcommand of `fetch`.
    func testTheLeafIsRegisteredUnderFetch() throws {
        XCTAssertTrue(FetchCommand.configuration.subcommands.contains { $0 == PathoplexusSubcommand.self })
        let command = try FetchCommand.parseAsRoot(["pathoplexus", "PP_0012345", "--organism", "mpox"])
        XCTAssertTrue(command is PathoplexusSubcommand, "\(type(of: command))")
    }
}
