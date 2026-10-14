// BrackenFailureMessage.swift - The message of a Bracken run that exited with a failure
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The message a failed Bracken run gives the row's detail and its warning (Phase 2.10 U34, W4).
///
/// Bracken's whole standard error is a Python traceback or an argparse usage block, and the record of the
/// run keeps all of it in the step's `stderr`. The row shows one line, the last line Bracken wrote, which is
/// the exception that ends a traceback and the `est_abundance.py: error: …` line that ends an argparse
/// refusal. That line can name the scratch copy of the report that Bracken was given, a path under the
/// system's temporary folder, so it passes through the rewrite the record applies to a step written beside
/// the report. Inside a project that path reads `<workspace>/lungfish-bracken-<id>/classification.kreport`,
/// the text the record holds. Outside a project the record keeps the real path, and so does the message.
enum BrackenFailureMessage {
    /// The message of a Bracken run that exited with `exitCode` after it wrote `stderr`.
    ///
    /// A run that wrote nothing says why it has no line of its own, that the managed environment had no
    /// Bracken (exit 127) or the status it exited with.
    ///
    /// - Parameter reportURL: The Kraken report the run profiles. It lies in the result folder, where the
    ///   record is written, so its place says whether the message is shown inside a project.
    static func text(stderr: String, exitCode: Int32, reportURL: URL) -> String {
        if let line = lastLine(of: stderr) {
            return PortablePath.sanitize(text: line, forFileAt: reportURL)
        }
        return exitCode == 127
            ? "Bracken executable was not available in the managed environment."
            : "Bracken exited with status \(exitCode)."
    }

    /// The last line of `stderr` that holds more than white space, without its indentation, or nil when
    /// there is none.
    static func lastLine(of stderr: String) -> String? {
        for line in stderr.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
