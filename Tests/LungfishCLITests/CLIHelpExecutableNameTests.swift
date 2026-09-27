// CLIHelpExecutableNameTests.swift - Help text names the executable as it is installed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import ArgumentParser
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO

/// The command-line executable is installed as `lungfish-cli` (SwiftPM
/// product, `Contents/MacOS/lungfish-cli` in the app bundle, and the name
/// the manual documents). Help examples, discussions and error hints used
/// to spell it `lungfish <subcommand>`, which does not exist on any PATH.
/// This walks the whole command tree so a new command cannot bring the old
/// spelling back. Provenance workflow names (`"lungfish import vcf"`) are
/// identifiers, not commands, and are outside this check.
final class CLIHelpExecutableNameTests: XCTestCase {
    private static let topLevelCommandNames: [String] = LungfishCLI.configuration.subcommands
        .compactMap { $0.configuration.commandName }

    /// `lungfish <top-level command>` not preceded by a word character, `.`,
    /// `-` or `/` (so `.lungfish`, `lungfish-cli` and paths do not match).
    private static let legacySpelling: NSRegularExpression = {
        let alternatives = topLevelCommandNames.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(
            pattern: "(?<![\\w./-])\(CLICommandIdentity.legacyExecutableName) (?:\(alternatives))\\b")
    }()

    private static func legacyMatches(in text: String) -> [String] {
        legacySpelling.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func walk(_ command: ParsableCommand.Type, path: [String], into visited: inout [(path: [String], type: ParsableCommand.Type)]) {
        visited.append((path, command))
        for subcommand in command.configuration.subcommands {
            let name = subcommand.configuration.commandName ?? String(describing: subcommand)
            walk(subcommand, path: path + [name], into: &visited)
        }
    }

    func testTheRootCommandIsNamedLungfishCli() {
        XCTAssertEqual(LungfishCLI.configuration.commandName, "lungfish-cli")
        XCTAssertEqual(CLICommandIdentity.executableName, "lungfish-cli")
        XCTAssertFalse(Self.topLevelCommandNames.isEmpty)
    }

    func testTheRegexCatchesTheOldSpellingAndSkipsFalsePositives() {
        XCTAssertEqual(Self.legacyMatches(in: "Run `lungfish bundle info x` first"), ["lungfish bundle"])
        XCTAssertEqual(Self.legacyMatches(in: "  lungfish fastq subsample reads.fastq"), ["lungfish fastq"])
        XCTAssertTrue(Self.legacyMatches(in: "Run `lungfish-cli bundle info x`").isEmpty)
        XCTAssertTrue(Self.legacyMatches(in: "a Project.lungfish bundle").isEmpty)
        XCTAssertTrue(Self.legacyMatches(in: "Lungfish Genome Explorer imports").isEmpty)
        XCTAssertTrue(Self.legacyMatches(in: "the lungfish genome folder").isEmpty)
        // `project` is itself a command, so prose such as "the lungfish
        // project" is reported too; help text says "LGE project" instead.
        XCTAssertEqual(Self.legacyMatches(in: "the lungfish project folder"), ["lungfish project"])
    }

    /// Every command's help (usage, abstract, discussion, option help,
    /// including hidden subcommands) spells the executable `lungfish-cli`.
    func testNoHelpTextSpellsTheExecutableAsBareLungfish() {
        var commands: [(path: [String], type: ParsableCommand.Type)] = []
        Self.walk(LungfishCLI.self, path: [], into: &commands)
        XCTAssertGreaterThan(commands.count, 100, "expected the full command tree")

        var offenders: [String] = []
        for (path, type) in commands {
            let help = type.helpMessage(includeHidden: true, columns: 200)
            let matches = Self.legacyMatches(in: help)
            if !matches.isEmpty {
                offenders.append("\(path.joined(separator: " ")): \(Set(matches).sorted().joined(separator: ", "))")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "help text still spells the executable `lungfish`:\n" + offenders.joined(separator: "\n"))
    }

    /// `msa actions` prints each action's CLI command template.
    func testMSAActionCommandTemplatesNameTheExecutable() {
        for action in MultipleSequenceAlignmentActionRegistry.actions {
            guard let command = action.cli?.command, !command.isEmpty else { continue }
            XCTAssertTrue(command.hasPrefix("lungfish-cli "), "\(action.id): \(command)")
        }
    }
}
