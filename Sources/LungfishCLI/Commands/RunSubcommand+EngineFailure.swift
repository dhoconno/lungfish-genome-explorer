// RunSubcommand+EngineFailure.swift - The failure reason for a non-zero engine exit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension RunSubcommand {
    /// Builds the failure reason for a non-zero engine exit.
    ///
    /// The app writes the CLI's own stderr to `logs/lungfish-cli.stderr.log` once
    /// the command returns, so `logs/stderr.log` stays the engine's. The engine's
    /// last stderr lines ride along in the reason all the same, so the operation
    /// report shows the actual cause (for example a launcher that could not be found).
    static func engineFailureReason(
        engineName: String,
        exitCode: Int32,
        stderr: String,
        runBundleURL: URL,
        maxLines: Int = 20
    ) -> String {
        var reason = "\(engineName) exited with status \(exitCode). See \(runBundleURL.appendingPathComponent("logs/stderr.log").path)"
        let tail = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(maxLines)
        if !tail.isEmpty {
            reason += "\n" + tail.joined(separator: "\n")
        }
        return reason
    }
}
