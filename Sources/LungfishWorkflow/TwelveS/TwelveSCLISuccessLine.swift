// TwelveSCLISuccessLine.swift - The last line a successful `lungfish-cli fastq 12s-*` command prints
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The last line of a successful 12S command, which names what it wrote.
///
/// The line goes to standard output. Standard error carries the `[NN%]`
/// progress lines and real warnings only. The app logs every standard error
/// line that is not progress as a warning, and a row with a warning reads
/// Completed with Warnings, so these lines on standard error made every clean
/// 12S run read that way (walk F7).
///
/// The five 12S subcommands print their line here, and so does every test
/// that stands in for one, so the wording and the stream have one home.
/// `FastqTwelveSMatchSubcommandTests` runs each command in process and checks
/// which stream its line lands on.
public struct TwelveSCLISuccessLine: Equatable, Sendable {
    /// The line without its newline.
    public let text: String

    private init(_ text: String) {
        self.text = text
    }

    /// `fastq 12s-match` wrote a result bundle.
    public static func matchResult(_ bundleURL: URL) -> TwelveSCLISuccessLine {
        TwelveSCLISuccessLine("12S amplicon result bundle written to \(bundleURL.path)")
    }

    /// `fastq 12s-reference-bundle` wrote a reference bundle.
    public static func referenceBundle(_ bundleURL: URL) -> TwelveSCLISuccessLine {
        TwelveSCLISuccessLine("12S reference bundle written to \(bundleURL.path)")
    }

    /// `fastq 12s-reference-metadata` wrote a target metadata table.
    public static func targetMetadata(_ tableURL: URL) -> TwelveSCLISuccessLine {
        TwelveSCLISuccessLine("12S target metadata written to \(tableURL.path)")
    }

    /// `fastq 12s-export` wrote a species report.
    public static func export(_ reportURL: URL) -> TwelveSCLISuccessLine {
        TwelveSCLISuccessLine("12S export written to \(reportURL.path)")
    }

    /// `fastq 12s-export-unresolved` wrote a FASTA of unresolved sequences.
    public static func unresolvedFASTA(_ fastaURL: URL) -> TwelveSCLISuccessLine {
        TwelveSCLISuccessLine("12S unresolved FASTA written to \(fastaURL.path)")
    }

    /// Writes the line and its newline to standard output, unbuffered, so a
    /// reader on a pipe has it as soon as the command ends. A write that fails
    /// is ignored, because the result is already on disk and a closed pipe
    /// must not turn a finished run into a failed one.
    public func write() {
        try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8))
    }
}
