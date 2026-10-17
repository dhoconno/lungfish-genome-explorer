// ExtractTaxaCollectionCommandTests.swift - The options of extract taxa-collection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A66 M2. The command takes the taxa of a collection as `--target
// <taxId>,<children|exact>,<display name>` values, and refuses a value that is anything else when it
// parses, before any file is read. The run itself is covered by the parity and SIGTERM replay classes
// of the app tests, which launch the built command.

import ArgumentParser
import XCTest
@testable import LungfishCLI
import LungfishCore

final class ExtractTaxaCollectionCommandTests: XCTestCase {
    private func parse(_ targets: [String]) throws -> ExtractTaxaCollectionSubcommand {
        try ExtractTaxaCollectionSubcommand.parse(
            ["--result", "/tmp/result", "--collection-id", "c", "--collection-name", "C", "--output-dir", "/tmp/out", "--format", "json"]
                + targets.flatMap { ["--target", $0] }
        )
    }

    func testTargetsParseWithTheirScopeAndName() throws {
        let command = try parse(["11320,children,Influenza A virus", "12814,exact,RSV, subtype A"])

        let targets = try command.targets.map(ExtractTaxaCollectionSubcommand.parseTarget)
        XCTAssertEqual(targets.map(\.taxId), [11320, 12814])
        XCTAssertEqual(targets.map(\.includeChildren), [true, false])
        XCTAssertEqual(targets.map(\.displayName), ["Influenza A virus", "RSV, subtype A"], "the name is the rest of the value")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
    }

    func testAMalformedTargetIsRefusedWhenTheCommandParses() {
        for target in ["abc,children,X", "11320,all,X", "11320,children,", "0,exact,X", "11320", "-5,exact,X"] {
            XCTAssertThrowsError(try parse([target]), target)
        }
    }

    func testACommandWithNoTargetIsRefused() {
        XCTAssertThrowsError(try parse([]))
    }

    func testTheLeafIsRegisteredUnderExtract() {
        XCTAssertTrue(ExtractCommand.configuration.subcommands.contains { $0 == ExtractTaxaCollectionSubcommand.self })
        XCTAssertEqual(ExtractTaxaCollectionSubcommand.configuration.commandName, "taxa-collection")
    }
}
