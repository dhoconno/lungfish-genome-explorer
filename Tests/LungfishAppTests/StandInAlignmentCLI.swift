// StandInAlignmentCLI.swift - A stand-in lungfish-cli for the tests of the L3 runner
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A54. The tests of the Inspector's alignment workflow routes run the app's L3 runner
// against a shell script in place of the built CLI, through `CLIAlignmentActionRunner(cliURLOverride:)`.
// The script writes the arguments it got, one to a line, and an empty `started` file, and then runs the
// body the test gives it, which prints the events of the run it stands for. No real tool is needed.

import Foundation

struct StandInAlignmentCLI {
    let cli: URL
    private let argvFile: URL
    /// Exists once the script is running.
    let startedFile: URL

    /// Writes the script into `root`. `body` is shell text that runs after the script recorded its arguments.
    static func make(in root: URL, body: String) throws -> StandInAlignmentCLI {
        let stand = StandInAlignmentCLI(
            cli: root.appendingPathComponent("lungfish-cli"),
            argvFile: root.appendingPathComponent("stand-in-argv.txt"),
            startedFile: root.appendingPathComponent("stand-in-started")
        )
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(stand.argvFile.path)'
        : > '\(stand.startedFile.path)'
        \(body)
        """
        try script.write(to: stand.cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stand.cli.path)
        return stand
    }

    /// The arguments the script was started with, or nil before it ran.
    func arguments() -> [String]? {
        guard let text = try? String(contentsOf: argvFile, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// One `CLIEvent` line for a script body, printed with `printf` so the shell adds no escapes.
    static func line(_ json: String) -> String {
        "printf '%s\\n' '\(json)'"
    }
}
