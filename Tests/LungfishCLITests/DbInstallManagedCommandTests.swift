// DbInstallManagedCommandTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Argument-surface tests for `lungfish conda db install-managed`, the CLI entry
// point that provisions the manifest's managedData databases (the Deacon
// panhuman host-depletion index and friends). Installing one downloads a
// multi-GB payload, so these tests cover only parsing, identifier validation,
// and the --list path; the install itself is exercised by the
// toolset-conformance CI job.

import ArgumentParser
import XCTest
@testable import LungfishCLI
import LungfishWorkflow

final class DbInstallManagedCommandTests: XCTestCase {

    func testSubcommandIsRegisteredUnderDb() {
        let names = DbCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("install-managed"), "registered subcommands: \(names)")
    }

    func testParsesADatabaseIdentifier() throws {
        let command = try DbCommand.DbInstallManagedSubcommand.parse(["deacon-panhuman"])
        XCTAssertEqual(command.databaseID, "deacon-panhuman")
        XCTAssertFalse(command.list)
        XCTAssertFalse(command.reinstall)
    }

    func testParsesListFlagWithoutAnIdentifier() throws {
        let command = try DbCommand.DbInstallManagedSubcommand.parse(["--list"])
        XCTAssertTrue(command.list)
        XCTAssertNil(command.databaseID)
    }

    func testParsesReinstallFlag() throws {
        let command = try DbCommand.DbInstallManagedSubcommand.parse(["deacon-panhuman", "--reinstall"])
        XCTAssertTrue(command.reinstall)
    }

    /// The identifier the CI job passes has to be one the registry actually
    /// knows, or the job would fail at provisioning time rather than here.
    func testDeaconPanhumanIsAKnownManagedIdentifier() {
        XCTAssertTrue(DatabaseRegistry.knownIDs.contains("deacon-panhuman"))
    }

    /// Legacy aliases resolve, so `--list` output and accepted input agree.
    func testAliasesResolveToKnownIdentifiers() {
        XCTAssertEqual(DatabaseRegistry.canonicalDatabaseID(for: "deacon"), "deacon-panhuman")
        XCTAssertTrue(
            DatabaseRegistry.knownIDs.contains(DatabaseRegistry.canonicalDatabaseID(for: "deacon"))
        )
    }
}
