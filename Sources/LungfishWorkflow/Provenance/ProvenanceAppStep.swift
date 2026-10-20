// ProvenanceAppStep.swift - The one list and one predicate for a step that ran inside the app
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A step that ran inside the app, such as the merge of FASTQ bundles, has no command that a Terminal can run,
/// whatever words its record keeps (V1-7, R3 of BIO-Q-A2). The exporter reads this list to leave the step out of
/// every replay, and the Provenance tab reads it to turn off Copy Command for the step.
public enum ProvenanceAppStep {
    /// The executable names a record keeps when the app itself ran the step, in lower case. A word is compared by its
    /// last path component, so `/Applications/Lungfish.app` names `lungfish.app`.
    public static let names: [String] = ["lungfish.app", "lungfish-app", "lungfish-gui", "lungfish genome explorer"]

    /// Whether `argv` records a step that ran inside the app. The step's executable is `argv[0]`, or the first word
    /// of the script when `argv` is `sh`, `bash` or `zsh` with `-c` or `-lc` and a script. An empty argv is no app step.
    public static func isAppStep(_ argv: [String]) -> Bool {
        guard let executable = argv.first, !executable.isEmpty else { return false }
        let name = lastComponent(of: executable)
        if names.contains(name) { return true }
        guard ["sh", "bash", "zsh"].contains(name), argv.count >= 3, ["-c", "-lc"].contains(argv[1]),
              let first = try? AdvancedCommandLineOptions.parse(argv[2]).first else { return false }
        return names.contains(lastComponent(of: first))
    }

    private static func lastComponent(of word: String) -> String {
        URL(fileURLWithPath: word).lastPathComponent.lowercased()
    }
}
