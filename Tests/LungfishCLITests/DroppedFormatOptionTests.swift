// DroppedFormatOptionTests.swift - A leaf that writes human text only lists no --format
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A55 (2.6 row 213), milestone M3. A leaf that listed `--format json` and never read it
// either honours the option or drops it. A dropped leaf hides its `GlobalOptions` group with
// `@OptionGroup(visibility: .hidden)` and its contract row says `humanTextOnly`. The group keeps its type, so
// the root command and the leaf still share each parsed value. A different type does not share them, because
// ArgumentParser hands a leaf's `@OptionGroup` the value its parent decoded for the same type, so the root
// would take `--threads` and the leaf would read nil (`SubcommandThreadsOptionTests`). These cases read the
// help of every leaf in the command tree, so a row and its help cannot part, and parse a dropped leaf through
// the real root parser to show that the global options still reach it.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishWorkflow

final class DroppedFormatOptionTests: XCTestCase {
    /// Every leaf of the command tree by its path, the way `CLIEventContractCoverageTests` walks it.
    private static func leafTypes() -> [String: ParsableCommand.Type] {
        var leaves: [String: ParsableCommand.Type] = [:]
        func walk(_ command: ParsableCommand.Type, _ path: [String]) {
            let subcommands = command.configuration.subcommands
            if subcommands.isEmpty {
                leaves[path.joined(separator: " ")] = command
                return
            }
            for subcommand in subcommands {
                walk(subcommand, path + [subcommand._commandName])
            }
        }
        walk(LungfishCLI.self, [])
        return leaves
    }

    func testNoLeafWhoseRowIsHumanTextOnlyListsAFormatOption() {
        let leaves = Self.leafTypes()
        var listing: [String] = []
        var checked = 0
        for (path, contract) in CLIEventContractTable.entries.sorted(by: { $0.key < $1.key }) {
            guard case let .text(reason) = contract, reason.hasPrefix("text output only"),
                  let type = leaves[path] else { continue }
            checked += 1
            if type.helpMessage(columns: 100).contains("--format") { listing.append(path) }
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertEqual(listing, [], "A leaf with a humanTextOnly row lists no --format, so its help promises no JSON")
    }

    func testADroppedLeafStillParsesTheGlobalOptionsAfterItsName() throws {
        // `workflow list` is the smallest of the leaves dropped in 2.10.
        let parsed = try LungfishCLI.parseAsRoot(["workflow", "list", "--format", "json", "--quiet", "--threads", "3"])
        let leaf = try XCTUnwrap(parsed as? ListSubcommand, "parsed \(Swift.type(of: parsed))")
        XCTAssertEqual(leaf.globalOptions.outputFormat, .json, "A script that passes --format keeps running")
        XCTAssertTrue(leaf.globalOptions.quiet)
        XCTAssertEqual(leaf.globalOptions.threads, 3)
        XCTAssertFalse(ListSubcommand.helpMessage(columns: 100).contains("--format"))
    }

    /// Hiding the group takes the `--threads` line out of the help, so each dropped leaf that reads the count says
    /// so in its own words (A55 review, ruling 2). The three that already did stay as they are.
    func testEachDroppedLeafThatReadsThreadsNamesItInItsHelp() throws {
        let leaves = Self.leafTypes()
        for path in ["fastq deacon-ribo", "fastq demultiplex", "fastq entropy-filter", "fastq ribodetector",
                     "import metadata", "nao-mgs import", "orient", "variants phase"] {
            let type = try XCTUnwrap(leaves[path], path)
            XCTAssertTrue(type.helpMessage(columns: 100).contains("--threads"), "\(path) reads --threads, so its help names it")
        }
    }

    func testADroppedLeafHidesTheWholeGroupAsTheTextOnlyLeavesDo() {
        let help = ListSubcommand.helpMessage(columns: 100)
        for option in ["--format", "--verbose", "--quiet", "--no-color", "--threads"] {
            XCTAssertFalse(help.contains(option), "\(option) is parsed and not listed")
        }
        XCTAssertTrue(help.contains("--nf-core"), "The leaf's own option stays listed")
    }
}
