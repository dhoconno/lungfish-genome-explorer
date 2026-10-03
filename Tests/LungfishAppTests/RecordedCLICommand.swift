// RecordedCLICommand.swift - Parses an Operations panel command with the real lungfish-cli parser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every operation records the lungfish-cli command that reproduces it (R4 in
// docs/reports/2026-10-02-architecture-review/REVIEW.md). A recorded string
// that the CLI cannot parse is drift between the GUI and the CLI. These
// helpers turn the string back into argv with the inverse of
// `OperationCenter.buildCLICommand` and hand it to `LungfishCLI.parseAsRoot`,
// the parser the shipped binary runs.

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
@testable import LungfishCLI
import LungfishKit
import LungfishWorkflow

enum RecordedCLICommand {
    enum ParseError: Error, CustomStringConvertible {
        case missingCommand
        case notALungfishCLICommand(String)
        case emptyScript
        case argumentOutsideRoot(argument: String, root: String)
        case nothingRebased(root: String)

        var description: String {
            switch self {
            case .missingCommand:
                return "The operation recorded no CLI command."
            case .notALungfishCLICommand(let command):
                return "The recorded command does not start with \(CLICommandIdentity.executableName): \(command)"
            case .emptyScript:
                return "The recorded command script holds no command."
            case .argumentOutsideRoot(let argument, let root):
                return "The argument \(argument) names \(root) but does not start with it."
            case .nothingRebased(let root):
                return "No argument of the recorded command starts with \(root)."
            }
        }
    }

    /// Splits `command` into the arguments that follow `lungfish-cli`.
    ///
    /// `AdvancedCommandLineOptions.parse` is the inverse of the quoting
    /// `OperationCenter.buildCLICommand` applies (`shellEscape` on each
    /// argument, joined by spaces).
    static func arguments(of command: String?) throws -> [String] {
        guard let command else { throw ParseError.missingCommand }
        let words = try AdvancedCommandLineOptions.parse(command)
        guard words.first == CLICommandIdentity.executableName else {
            throw ParseError.notALungfishCLICommand(command)
        }
        return Array(words.dropFirst())
    }

    /// Parses `command` the way the shipped binary does. The arguments go
    /// through `LungfishCLI.normalizedArgumentsForParsing`, as in
    /// `LungfishCLIMain.main`, then `LungfishCLI.parseAsRoot`, which also runs
    /// each command's `validate()`.
    static func parse(_ command: String?) throws -> any ParsableCommand {
        let arguments = try arguments(of: command)
        return try LungfishCLI.parseAsRoot(LungfishCLI.normalizedArgumentsForParsing(arguments))
    }

    /// Parses `command` and requires the subcommand type `type`.
    static func parse<Command: ParsableCommand>(
        _ command: String?,
        as type: Command.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Command {
        let parsed = try parse(command)
        return try XCTUnwrap(
            parsed as? Command,
            "Parsed \(Swift.type(of: parsed)), expected \(Command.self), from: \(command ?? "nil")",
            file: file,
            line: line
        )
    }
}

// MARK: - Command scripts and replay

extension RecordedCLICommand {
    /// Parses a recorded command script, which is one `lungfish-cli` command
    /// per line (docs/contracts/CLI-EQUIVALENCE.md). Every line must parse on
    /// its own. A nil or empty script throws, so a row that records nothing
    /// never passes as a command.
    static func parseScript(_ script: String?) throws -> [any ParsableCommand] {
        guard let script else { throw ParseError.missingCommand }
        let lines = script.components(separatedBy: "\n")
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw ParseError.emptyScript
        }
        return try lines.map { try parse($0) }
    }

    /// Rewrites every argument of `command` that starts with `rootA` so it
    /// starts with `rootB` instead, line by line, and quotes the result the
    /// way `OperationCenter.buildCLICommand` does.
    ///
    /// An argument that names `rootA` anywhere but at its start throws,
    /// because a replay would then read or write the first run's files. A
    /// script with no argument under `rootA` throws too, because its replay
    /// would compare a run with itself.
    static func rebased(_ command: String, from rootA: URL, to rootB: URL) throws -> String {
        let spellingsA = rootSpellings(rootA)
        let pathB = rootB.standardizedFileURL.path
        var replaced = 0
        let lines = try command.components(separatedBy: "\n").map { line -> String in
            let words = try AdvancedCommandLineOptions.parse(line)
            guard words.first == CLICommandIdentity.executableName else {
                throw ParseError.notALungfishCLICommand(line)
            }
            let rebasedWords = try words.dropFirst().map { word -> String in
                if let spelling = spellingsA.first(where: { word == $0 || word.hasPrefix($0 + "/") }) {
                    replaced += 1
                    return pathB + word.dropFirst(spelling.count)
                }
                if let spelling = spellingsA.first(where: { word.contains($0 + "/") || word.hasSuffix($0) }) {
                    throw ParseError.argumentOutsideRoot(argument: word, root: spelling)
                }
                return word
            }
            return OperationCenter.buildCLICommand(subcommand: "", args: Array(rebasedWords))
        }
        guard replaced > 0 else { throw ParseError.nothingRebased(root: rootA.path) }
        return lines.joined(separator: "\n")
    }

    /// Parses each line of `script` and runs it in this process, in order,
    /// the way `LungfishCLIMain.main` runs the shipped binary.
    static func runInProcess(_ script: String) async throws {
        for command in try parseScript(script) {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                var syncCommand = command
                try syncCommand.run()
            }
        }
    }

    /// Every spelling of a temporary root. Foundation drops a leading
    /// `/private` from `/private/var` and `/private/tmp` when it standardizes
    /// a path, so a recorded command may carry either form. Longest first, so
    /// the most specific spelling is replaced.
    private static func rootSpellings(_ root: URL) -> [String] {
        var forms: Set<String> = [
            root.path,
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().path,
        ]
        for form in forms {
            if form.hasPrefix("/private/") {
                forms.insert(String(form.dropFirst("/private".count)))
            } else if form.hasPrefix("/var/") || form.hasPrefix("/tmp/") {
                forms.insert("/private" + form)
            }
        }
        return forms
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .sorted { $0.count > $1.count }
    }
}

/// Pins a CLI parity gap. The row's recorded command must fail
/// `RecordedCLICommand.parseScript`, and `id` names the marker
/// `cli-parity-gap: <id>` on the begin helper. When a command lands, this
/// assertion fails, and the change replaces it with a parse test and a replay
/// test and removes the marker (docs/contracts/CLI-EQUIVALENCE.md).
/// `scripts/ratchets/cli-parity-gaps.sh` matches each `id` with a marker.
func assertCLIParityGap(
    _ command: String?,
    id: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertThrowsError(
        try RecordedCLICommand.parseScript(command),
        "CLI parity gap \(id) now records a command that parses: \(command ?? "nil"). "
            + "Replace this pin with a parse test and a replay test, and remove the cli-parity-gap marker.",
        file: file,
        line: line
    )
}
