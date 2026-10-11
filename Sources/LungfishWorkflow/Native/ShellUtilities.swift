// ShellUtilities.swift - Shared shell escaping and version detection utilities
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - Shell Escaping

/// Escapes a string for safe use in a POSIX shell command.
///
/// Wraps the value in single quotes if it contains characters that
/// require escaping (spaces, parentheses, dollar signs, etc.).
/// Single quotes within the value are escaped as `'\''`.
///
/// This is a module-level free function to avoid `@MainActor` isolation
/// issues when called from `@Sendable` contexts.
///
/// - Parameter value: The raw string to escape.
/// - Returns: A shell-safe representation of the string.
public func shellEscape(_ value: String) -> String {
    if value.isEmpty { return "''" }
    // Characters that are safe unquoted in POSIX shells
    let safeCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: "-_./:=@+,"))
    if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
        return value
    }
    // Wrap in single quotes, escaping any embedded single quotes
    let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
    return "'\(escaped)'"
}

public enum AdvancedCommandLineOptionsError: Error, LocalizedError, Equatable {
    case unterminatedQuote(Character)
    case trailingEscape

    public var errorDescription: String? {
        switch self {
        case .unterminatedQuote(let quote):
            return "Advanced options contain an unterminated \(quote) quote."
        case .trailingEscape:
            return "Advanced options end with an unfinished escape sequence."
        }
    }
}

public enum AdvancedCommandLineOptions {
    public static func parse(_ text: String) throws -> [String] {
        var arguments: [String] = []
        var current = ""
        var currentStarted = false
        var activeQuote: Character?
        var escaping = false

        for character in text {
            if escaping {
                current.append(character)
                currentStarted = true
                escaping = false
                continue
            }

            if character == "\\" && activeQuote != "'" {
                escaping = true
                currentStarted = true
                continue
            }

            if let quote = activeQuote {
                if character == quote {
                    activeQuote = nil
                } else {
                    current.append(character)
                }
                currentStarted = true
                continue
            }

            if character == "'" || character == "\"" {
                activeQuote = character
                currentStarted = true
                continue
            }

            if character.isWhitespace {
                if currentStarted {
                    arguments.append(current)
                    current.removeAll(keepingCapacity: true)
                    currentStarted = false
                }
                continue
            }

            current.append(character)
            currentStarted = true
        }

        if escaping {
            throw AdvancedCommandLineOptionsError.trailingEscape
        }
        if let activeQuote {
            throw AdvancedCommandLineOptionsError.unterminatedQuote(activeQuote)
        }
        if currentStarted {
            arguments.append(current)
        }
        return arguments
    }

    public static func join(_ arguments: [String]) -> String {
        arguments.map(shellEscape).joined(separator: " ")
    }
}

// MARK: - Version Detection

/// Detects a tool's version by running it with version flags in a conda environment.
///
/// When `condaPackage` names the package that ships the tool, the installed
/// version is read from the environment's `conda-meta` record and no probe
/// runs. Otherwise, or when that record is missing, tries `--version` first,
/// then `-v` as a fallback, and parses the output with `parseToolVersion(from:)`.
///
/// - Parameters:
///   - toolName: The tool executable name (e.g. `"kraken2"`, `"EsViritu"`).
///   - environment: The conda environment name where the tool is installed.
///   - condaManager: The conda manager to use for execution.
///   - condaPackage: The conda package whose installed version is the tool's
///     version (e.g. `"esviritu"`). Pass it for a tool whose own version
///     output is unreliable to parse.
///   - flags: Version flags to try in order (default: `["--version", "-v"]`).
///   - timeout: Timeout per attempt in seconds (default: 30).
/// - Returns: The version string, or `"unknown"` if detection fails.
/// - Throws: `CancellationError` if the enclosing task is cancelled while a
///   probe is in flight. `condaManager.runTool` kills the probe
///   process and throws `CancellationError` on cancellation, but this
///   function used to catch every error indiscriminately and move on to the
///   next flag, silently absorbing the cancellation and returning
///   `"unknown"` as if detection had merely failed. The caller (a pipeline's
///   `detect`/`classify`/`profile`) would then keep running past the point
///   where the user cancelled, and no later step in that pipeline checks
///   `Task.isCancelled` either — so the operation ran to completion or
///   failure instead of ever reaching `OperationCenter`'s cancelled state.
///   Rethrowing here lets the pipeline's own `catch` clause (which every
///   caller already has) reach `OperationCenter.fail`/`.acknowledgeCancellation`
///   promptly, the same terminal-state guarantee `CLIImportRunner` gives
///   CLI-driven imports.
func detectToolVersion(
    toolName: String,
    environment: String,
    condaManager: CondaManager,
    condaPackage: String? = nil,
    flags: [String] = ["--version", "-v"],
    timeout: TimeInterval = 30
) async throws -> String {
    if let condaPackage {
        let environmentURL = await condaManager.environmentURL(named: environment)
        if let package = CondaMetaReader.primaryPackage(named: condaPackage, inEnvironment: environmentURL) {
            return package.version
        }
    }
    for flag in flags {
        do {
            let result = try await condaManager.runTool(
                name: toolName,
                arguments: [flag],
                environment: environment,
                timeout: timeout
            )
            if let version = parseToolVersion(from: result.stdout + result.stderr) {
                return version
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            continue
        }
    }
    if Task.isCancelled { throw CancellationError() }
    return "unknown"
}

/// Extracts a version from a tool's `--version` style output.
///
/// Returns the first semver-like pattern (e.g. `2.1.3`) outside any file
/// path, else the first output line, else `nil` for empty output. Paths are
/// skipped because several tools print their own location before the
/// version. EsViritu prints `.../lib/python3.14/site-packages/EsViritu`
/// then `1.3.3`, and a match inside that path recorded Python's `3.14` as
/// EsViritu's version. Bowtie2 and SKESA print their executable path too.
func parseToolVersion(from output: String) -> String? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lines = trimmed.components(separatedBy: .newlines)
    return ProbeVersionText.version(in: lines, skippingCommandEcho: false) ?? lines.first ?? trimmed
}

/// The rule the Workflow's two version parsers share for finding a version token.
///
/// `parseToolVersion(from:)` and `NativeToolRunner.parseVersionProbe` both call it. The CLI keeps
/// its own copy in `CLIProvenanceSupport.parseCondaToolVersion`, and sub-phase 2.7 merges the
/// three. A table of real probe output, `VersionParserOutputPinTests`, pins every tool's result.
enum ProbeVersionText {
    /// The first dotted number in the lines, left to right, outside any path.
    ///
    /// A token that holds a slash is a path, a URL or a DOI, and never counts. Several tools print
    /// their location before the version, and a volume name such as `LGE 2.0` splits a path on its
    /// space, so each half still holds a slash.
    ///
    /// `skippingCommandEcho` also skips a line that echoes a JVM command (`java -ea ...`). Every
    /// BBTools wrapper prints one before its banner, and it carries the install path and options
    /// such as `minratio=0.40`.
    static func version(in lines: [String], skippingCommandEcho: Bool) -> String? {
        let number = /\d+\.\d+(?:\.\d+)?/
        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            if skippingCommandEcho, tokens.count >= 2, tokens[0] == "java", tokens[1].hasPrefix("-") { continue }
            for token in tokens where !token.contains("/") {
                if let match = token.firstMatch(of: number) { return String(match.output) }
            }
        }
        return nil
    }
}
