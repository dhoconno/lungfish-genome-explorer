// BuildDatabaseTokenPinTests.swift - The word the app passes lungfish-cli build-db for each classifier
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The word that follows `lungfish-cli build-db` was the lowercased display name of the
// classifier. Panel decision S14 of Phase 2.6 moved it onto the analysis descriptor as
// `buildDatabaseToken`, and this suite freezes the argv the app launches. The classify output
// stems it also froze lost their last reader when lane A41 M3b of Phase 2.10 removed the dialog's
// classify request, and AnalysisToolRegistryTests pins the descriptor's `outputStem`.
//
// The argv is observed for real. A script stands in for `lungfish-cli` through
// `LUNGFISH_CLI_PATH`, records every argument it receives and fails, so the placeholder shows
// its error state and never retries. Two entry points reach the build, the database router
// (`routeClassifierDisplay`) and the batch display path (`displayBatchGroup`), and both are
// driven.

import AppKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishIO

@MainActor
final class BuildDatabaseTokenPinTests: XCTestCase {
    /// A classifier with a build-db subcommand and the word that subcommand takes.
    private struct Classifier {
        let name: String
        let token: String
        /// A folder name the app gave a run of this classifier.
        let batchFolder: String
    }

    private static let classifiers = [
        Classifier(name: "TaxTriage", token: "taxtriage", batchFolder: "taxtriage-batch-2026-04-06T20-46-18"),
        Classifier(name: "EsViritu", token: "esviritu", batchFolder: "esviritu-batch-2026-04-06T20-46-01"),
        Classifier(name: "Kraken2", token: "kraken2", batchFolder: "kraken2-batch-2026-04-06T20-45-49"),
    ]

    private var folder: URL!
    private var recordURL: URL!
    private var priorCLIPath: String?

    override func setUp() async throws {
        try await super.setUp()
        priorCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        folder = try TestTempDirectory.make(prefix: "build-db-token")
        recordURL = folder.appendingPathComponent("argv.log")
        try installRecordingCLI()
    }

    override func tearDown() async throws {
        if let priorCLIPath {
            setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1)
        } else {
            unsetenv("LUNGFISH_CLI_PATH")
        }
        if let folder { TestTempDirectory.cleanup(folder) }
        try await super.tearDown()
    }

    // MARK: - build-db argv

    func testRouterBuildsEveryClassifierDatabaseWithItsLowercasedName() async throws {
        for classifier in Self.classifiers {
            let result = try makeResultFolder(named: classifier.batchFolder)
            let argv = try await launchedArguments { $0.routeClassifierDisplay(url: result) }
            XCTAssertEqual(argv, ["build-db", classifier.token, result.path, "--force"], classifier.name)
        }
    }

    func testBatchDisplayBuildsEveryClassifierDatabaseWithItsLowercasedName() async throws {
        for classifier in Self.classifiers {
            let result = try makeResultFolder(named: classifier.batchFolder)
            let argv = try await launchedArguments { $0.displayBatchGroup(at: result) }
            XCTAssertEqual(argv, ["build-db", classifier.token, result.path, "--force"], classifier.name)
        }
    }

    /// A renamed folder is identified by `analysis-metadata.json`, and the build still takes the
    /// classifier's word.
    func testRenamedFoldersBuildWithTheClassifiersWord() async throws {
        for classifier in Self.classifiers {
            let result = try makeResultFolder(named: "Weekly Surveillance \(classifier.name)")
            try AnalysesFolder.writeAnalysisMetadata(
                AnalysesFolder.AnalysisMetadata(tool: classifier.token, isBatch: true),
                to: result
            )
            let argv = try await launchedArguments { $0.routeClassifierDisplay(url: result) }
            XCTAssertEqual(argv, ["build-db", classifier.token, result.path, "--force"], classifier.name)
        }
    }

    /// The legacy `classification-` folder name is a Kraken2 result.
    func testLegacyClassificationFolderBuildsAKraken2Database() async throws {
        let result = try makeResultFolder(named: "classification-2026-04-06T20-45-49")
        let argv = try await launchedArguments { $0.routeClassifierDisplay(url: result) }
        XCTAssertEqual(argv, ["build-db", "kraken2", result.path, "--force"])
    }

    // MARK: - Harness

    private func makeController() -> (MainSplitViewController, NSWindow) {
        let controller = MainSplitViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.layoutIfNeeded()
        controller.view.layoutSubtreeIfNeeded()
        return (controller, window)
    }

    /// A result folder with no database, so selecting it starts a build.
    private func makeResultFolder(named name: String) throws -> URL {
        let result = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    /// Runs `trigger` on a fresh controller and returns the arguments the stand-in CLI received.
    private func launchedArguments(
        _ trigger: (MainSplitViewController) -> Void
    ) async throws -> [String] {
        try? FileManager.default.removeItem(at: recordURL)
        let (controller, window) = makeController()
        defer { window.contentViewController = nil }

        trigger(controller)

        let finished = await waitUntil(budget: .lookup) {
            (try? String(contentsOf: self.recordURL, encoding: .utf8))?.contains("--end--\n") == true
        }
        XCTAssertTrue(finished, "the build never started lungfish-cli")
        let lines = ((try? String(contentsOf: recordURL, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return Array(lines.prefix { $0 != "--end--" })
    }

    /// A script that records one argument per line and fails.
    private func installRecordingCLI() throws {
        let cli = folder.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        for argument in "$@"; do
          printf '%s\\n' "$argument" >> "\(recordURL.path)"
        done
        printf '%s\\n' '--end--' >> "\(recordURL.path)"
        exit 1
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
    }
}
