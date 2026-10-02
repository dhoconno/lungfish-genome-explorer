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
import LungfishWorkflow

enum RecordedCLICommand {
    enum ParseError: Error, CustomStringConvertible {
        case missingCommand
        case notALungfishCLICommand(String)

        var description: String {
            switch self {
            case .missingCommand:
                return "The operation recorded no CLI command."
            case .notALungfishCLICommand(let command):
                return "The recorded command does not start with \(CLICommandIdentity.executableName): \(command)"
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
