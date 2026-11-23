// LungfishCLIRunnerRecountTests.swift - The recount the app runs on display removes nothing (TT-LEGACY-CLEANUP-REMOVES-TOP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep before Preview 2026.11.17, lane TT-m1. The app recounts a TaxTriage result it shows through
// `LungfishCLIRunner.buildClassifierDatabase(tool:resultURL:force:sampleDirectories:)`
// (`MainSplitViewController+ClassifierDisplay.swift`). With no `--no-cleanup` the command's cleanup removed `top/` of an
// older result at its first open. A script stands in for `lungfish-cli` through `LUNGFISH_CLI_PATH` and writes the
// argv it was given, one argument a line.

import Foundation
import LungfishKit
import LungfishTestSupport
import XCTest

final class LungfishCLIRunnerRecountTests: XCTestCase {
    private var folder: URL!
    private var savedCLIPath: String?

    override func setUpWithError() throws {
        folder = try TestTempDirectory.make(prefix: "cli-runner-recount")
        savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        let cli = folder.appendingPathComponent("lungfish-cli")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(folder.appendingPathComponent("argv.txt").path)'\n"
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
    }

    override func tearDownWithError() throws {
        if let savedCLIPath {
            setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
        TestTempDirectory.cleanup(folder)
    }

    /// The argv the stand-in received for one `buildClassifierDatabase` call.
    private func argv(tool: String, result: URL) async throws -> [String] {
        try await Task.detached {
            try await LungfishCLIRunner.buildClassifierDatabase(tool: tool, resultURL: result, force: true)
        }.value
        let text = try String(contentsOf: folder.appendingPathComponent("argv.txt"), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// The recount of a TaxTriage result on display runs no cleanup, so it never removes `top/` of a folder with no
    /// record of `taxtriage run`, and removes nothing from a folder the app only shows (UX 6).
    func testRecountOnDisplayPassesNoCleanup() async throws {
        let result = folder.appendingPathComponent("taxtriage-batch", isDirectory: true)

        let arguments = try await argv(tool: "taxtriage", result: result)

        XCTAssertEqual(arguments, ["build-db", "taxtriage", result.path, "--force", "--no-cleanup"])
    }

    /// The lane changes the TaxTriage call alone. A Kraken2 recount keeps the argv it had.
    func testKraken2RecountKeepsItsArgv() async throws {
        let result = folder.appendingPathComponent("kraken2-batch", isDirectory: true)

        let arguments = try await argv(tool: "kraken2", result: result)

        XCTAssertEqual(arguments, ["build-db", "kraken2", result.path, "--force"])
    }
}
