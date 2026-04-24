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
/// Tries `--version` first, then `-v` as a fallback. Extracts the first
/// semver-like pattern (e.g. `2.1.3`) from the combined stdout+stderr output.
///
/// - Parameters:
///   - toolName: The tool executable name (e.g. `"kraken2"`, `"EsViritu"`).
///   - environment: The conda environment name where the tool is installed.
///   - condaManager: The conda manager to use for execution.
///   - flags: Version flags to try in order (default: `["--version", "-v"]`).
///   - timeout: Timeout per attempt in seconds (default: 30).
/// - Returns: The version string, or `"unknown"` if detection fails.
func detectToolVersion(
    toolName: String,
    environment: String,
    condaManager: CondaManager,
    flags: [String] = ["--version", "-v"],
    timeout: TimeInterval = 30
) async -> String {
    for flag in flags {
        do {
            let result = try await condaManager.runTool(
                name: toolName,
                arguments: [flag],
                environment: environment,
                timeout: timeout
            )
            let combined = result.stdout + result.stderr
            let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
            if let range = trimmed.range(
                of: #"\d+\.\d+(\.\d+)?"#,
                options: .regularExpression
            ) {
                return String(trimmed[range])
            }
            if !trimmed.isEmpty {
                return trimmed.components(separatedBy: .newlines).first ?? trimmed
            }
        } catch {
            continue
        }
    }
    return "unknown"
}
