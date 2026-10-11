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
            if let version = parseToolVersion(from: result.stdout, stderr: result.stderr, exitCode: result.exitCode) {
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
/// This is the detect call site of `ProbeVersionText.reading(exitCode:stdout:stderr:)`, which holds
/// every rule. `output` is the probe's stdout. The result is the first semver-like pattern
/// (e.g. `2.1.3`) outside any file path, with a token written `v2.31.0` preferred, else the first
/// stdout line when the probe exited 0 and the line does not read as an error, else `nil`.
/// bwa-mem2's `ERROR: unknown command '--version'` and micromamba's `critical libmamba ...` are
/// error lines and give no version. EsViritu prints `.../lib/python3.14/site-packages/EsViritu`
/// then `1.3.3`, and the path is skipped so Python's `3.14` is not read as EsViritu's version.
func parseToolVersion(from output: String, stderr: String = "", exitCode: Int32 = 0) -> String? {
    ProbeVersionText.reading(exitCode: exitCode, stdout: output, stderr: stderr)?.version
}

/// A version a probe printed and the output line it came from.
public struct ProbeVersionReading: Sendable, Hashable {
    /// The version as a record keeps it, such as `2.31` for the line `2.31-r1302`.
    public let version: String
    /// The output line the version came from, as the tool printed it with the space around it
    /// removed. It can hold the tool's install path, so whatever records it decides how.
    public let reportedLine: String

    public init(version: String, reportedLine: String) {
        self.version = version
        self.reportedLine = reportedLine
    }
}

/// The one rule that reads a tool version out of a version probe's output.
///
/// Every call site reads a probe through `reading(exitCode:stdout:stderr:)`. They are
/// `detectToolVersion` (by way of `parseToolVersion(from:)`), `NativeToolRunner.parseVersionProbe`
/// and the CLI's `CLIProvenanceSupport.detectCondaToolVersion`. A table of real probe output,
/// `VersionParserOutputPinTests`, pins the result for every tool they probe.
public enum ProbeVersionText {
    /// How many lines of each stream are read. A version sits at the top of a probe's output, and
    /// what lies deeper is build flags and licence text.
    private static let linesPerStream = 8

    /// Words that mark a line as a complaint about the probe and never a version. `critical` and
    /// `libmamba` are micromamba's log level and library name, so every line it writes is its own
    /// complaint, such as `critical libmamba The given prefix does not exist`.
    private static let probeErrorMarkers = [
        "fatal", "error", "unrecognized", "unrecognised", "unknown command", "unknown option",
        "usage", "invalid", "no such", "not found", "illegal", "not a valid",
        "critical", "libmamba",
    ]

    /// True for a line that reads as an error or a usage text.
    static func looksLikeProbeError(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return probeErrorMarkers.contains { lowered.contains($0) }
    }

    /// True when a line opens usage text, as `Usage: hifiasm [options]` does. Its first word is
    /// `usage` in any case, so a longer word (`usagestats`) or a word inside a line is not one.
    static func opensUsageText(_ line: String) -> Bool {
        line.split(whereSeparator: { $0.isWhitespace || $0 == ":" }).first?.lowercased() == "usage"
    }

    /// The lines before the first one that opens usage text. Usage text lists option defaults
    /// such as hifiasm's `-D FLOAT ... [5.0]` and holds no version, so nothing from that line on
    /// is read. A tool that prints its version before the usage block, as bwa and samtools do,
    /// keeps it.
    static func linesBeforeUsage(_ lines: [String]) -> [String] {
        Array(lines.prefix { !opensUsageText($0) })
    }

    /// The version a probe printed and the line it came from, or nil when it printed none.
    ///
    /// The first 8 lines of stdout and then of stderr are read, leaving blank lines out. In each
    /// stream the lines from the first one that opens usage text on are dropped, and so is every
    /// line that reads as an error, micromamba's own complaints included. The rest go to
    /// `reading(in:)`.
    ///
    /// A probe that printed no version number keeps the first line of stdout as its version when it
    /// exited 0 and the line does not read as an error, as a plain `nightly-build` does. A probe
    /// that exited nonzero keeps nothing, because its first line is the tool's complaint.
    public static func reading(exitCode: Int32, stdout: String, stderr: String) -> ProbeVersionReading? {
        let scanned = [stdout, stderr].flatMap { output in
            linesBeforeUsage(Array(significantLines(of: output).prefix(linesPerStream)))
                .filter { !looksLikeProbeError($0) }
        }
        if let found = reading(in: scanned) { return found }
        guard exitCode == 0, let firstLine = significantLines(of: stdout).first,
              !looksLikeProbeError(firstLine)
        else { return nil }
        return ProbeVersionReading(version: firstLine, reportedLine: firstLine)
    }

    /// The lines of an output that hold something, each without the space around it.
    private static func significantLines(of output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The version in the lines, outside any path. A token written `v2.31.0` is the tool naming
    /// its own version, so the first such token wins. Without one, the first dotted number wins.
    /// A version keeps up to four numeric parts, as GATK writes `4.6.2.0`, and a local build
    /// suffix after a plus sign, as primalscheme3 writes `3.3.0+lge.5`. It drops a suffix after
    /// a hyphen, such as minimap2's `-r1302`, and a bare trailing plus, as blastn writes `2.16.0+`.
    ///
    /// vsearch prints a zlib line (`zlib version 1.2.12`) on stdout before its banner
    /// (`vsearch v2.31.0_macos_aarch64`) on stderr, and the prefix is what tells them apart. A
    /// prefix wins even when it comes later than a bare number, so a tool that prints its own bare
    /// version and then names a library as `v2.0` would read the library.
    ///
    /// A token that holds a slash is a path, a URL or a DOI, and never counts. Several tools print
    /// their location before the version, and a volume name such as `LGE 2.0` splits a path on its
    /// space, so each half still holds a slash. A name of three words leaves a bare middle word,
    /// which 2.7 fixes by removing the storage root first.
    ///
    /// A line that echoes a JVM command (`java -ea ...`) is skipped. Every BBTools wrapper prints
    /// one before its banner, and it carries the install path and options such as `minratio=0.40`.
    static func reading(in lines: [String]) -> ProbeVersionReading? {
        let number = /\d+\.\d+(?:\.\d+){0,2}(?:\+[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?/
        var bare: ProbeVersionReading?
        for line in lines {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            if tokens.count >= 2, tokens[0] == "java", tokens[1].hasPrefix("-") { continue }
            for token in tokens where !token.contains("/") {
                guard let match = token.firstMatch(of: number) else { continue }
                let found = ProbeVersionReading(
                    version: String(match.output), reportedLine: line.trimmingCharacters(in: .whitespaces))
                let before = token[..<match.range.lowerBound]
                if before.last == "v", before.dropLast().allSatisfy({ !$0.isLetter && !$0.isNumber }) {
                    return found
                }
                if bare == nil { bare = found }
            }
        }
        return bare
    }
}
