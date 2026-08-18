// ToolsCommandTests.swift - Subprocess tests for `lungfish tools update`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Exercises `tools update` through the built CLI binary, because the contract under test
/// (exit codes, stdout purity in JSON mode) only exists at the process boundary.
final class ToolsCommandTests: XCTestCase {
    private var cliBinaryURL: URL? {
        let buildProductsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        return CLITestBinaryResolver.cliBinaryURL(
            repoRoot: CLITestBinaryResolver.repositoryRoot(containing: #filePath),
            buildProductsDirectory: buildProductsDirectory
        )
    }

    // MARK: - Plan

    func testPlanJSONOnEmptyRootListsRequiredInstalls() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["tools", "update", "--plan", "--json"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.updatesPending.rawValue, "stderr:\n\(result.stderr)")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            "stdout was not a JSON object:\n\(result.stdout)"
        )
        let installs = try XCTUnwrap(json["installEnvironments"] as? [[String: Any]])
        XCTAssertTrue(
            installs.contains { ($0["environment"] as? String) == "samtools" },
            "expected a samtools install in the plan for an empty storage root"
        )
        XCTAssertEqual(
            json["targetDependencySet"] as? String,
            ManagedToolLock.bundled.resolvedDependencySet
        )
    }

    func testPlanJSONWritesNothingButJSONToStandardOut() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["tools", "update", "--plan", "--json"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trimmed.hasPrefix("{"), "stdout should start with the JSON object:\n\(result.stdout)")
        XCTAssertTrue(trimmed.hasSuffix("}"), "stdout should end with the JSON object:\n\(result.stdout)")
    }

    func testPlanTextRendersTargetSetAndInstallLines() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["tools", "update", "--plan"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.updatesPending.rawValue, "stderr:\n\(result.stderr)")
        XCTAssertTrue(
            result.stdout.contains("Target dependency set: \(ManagedToolLock.bundled.resolvedDependencySet)"),
            "stdout:\n\(result.stdout)"
        )
        XCTAssertTrue(result.stdout.contains("install"), "stdout:\n\(result.stdout)")
    }

    /// The plan path must not need conda: it reads the filesystem and probes micromamba only
    /// when the binary is present, so an empty root has to answer promptly.
    func testPlanOnEmptyRootCompletesWithoutCondaQuickly() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let started = Date()
        let result = try runCLI(
            ["tools", "update", "--plan", "--json"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(result.exitCode, CLIExitCode.updatesPending.rawValue)
        XCTAssertLessThan(elapsed, 30, "planning on an empty storage root should not do network or conda work")
    }

    /// `--storage-root` has to move the conda root too, not just the receipt: a flag that
    /// redirected only one of them would compare one machine's receipt against another
    /// machine's installed environments.
    func testStorageRootFlagPlansTheSameAsTheEnvironmentOverride() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let viaFlag = try runCLI(
            ["tools", "update", "--plan", "--json", "--storage-root", root.path],
            environment: [:]
        )
        let viaEnvironment = try runCLI(
            ["tools", "update", "--plan", "--json"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(viaFlag.exitCode, viaEnvironment.exitCode)
        XCTAssertEqual(viaFlag.stdout, viaEnvironment.stdout)
    }

    /// A root the storage store refuses (here: not writable) must fail loudly rather than
    /// silently falling back to the machine's real storage location and planning against it.
    func testUnusableStorageRootIsRejectedRatherThanFallingBack() throws {
        let result = try runCLI(
            ["tools", "update", "--plan", "--storage-root", "/lungfish-tools-update-unwritable"],
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(result.stderr.contains("storage root"), "stderr:\n\(result.stderr)")
    }

    /// A root that does not exist yet but could be created is accepted, matching how
    /// `LUNGFISH_STORAGE_ROOT` behaves: the first apply creates it.
    func testCreatableStorageRootIsAccepted() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let child = parent.appendingPathComponent("not-yet-created", isDirectory: true)

        let result = try runCLI(
            ["tools", "update", "--plan", "--storage-root", child.path],
            environment: [:]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.updatesPending.rawValue, "stderr:\n\(result.stderr)")
    }

    // MARK: - Apply guards

    func testApplyRequiresYes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["tools", "update", "--apply"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.usage.rawValue)
        XCTAssertTrue(result.stderr.contains("--yes"), "stderr:\n\(result.stderr)")
    }

    func testApplyWithoutYesInJSONModeStillFailsBeforeDoingWork() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["tools", "update", "--apply", "--json"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.usage.rawValue)
        XCTAssertEqual(result.stdout, "", "JSON mode must not print a partial document:\n\(result.stdout)")
    }

    func testPlanAndApplyTogetherAreRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["tools", "update", "--plan", "--apply", "--yes"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.usage.rawValue)
        XCTAssertTrue(result.stderr.contains("mutually exclusive"), "stderr:\n\(result.stderr)")
    }

    // MARK: - db update guards

    func testDbUpdateRequiresYes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["conda", "db", "update", "--all"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(
            (result.stdout + result.stderr).contains("--yes"),
            "output:\n\(result.stdout)\(result.stderr)"
        )
    }

    func testDbUpdateRequiresATargetSelector() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runCLI(
            ["conda", "db", "update", "--yes"],
            environment: ["LUNGFISH_STORAGE_ROOT": root.path]
        )

        XCTAssertEqual(result.exitCode, CLIExitCode.inputError.rawValue)
        XCTAssertTrue(
            (result.stdout + result.stderr).contains("--all"),
            "output:\n\(result.stdout)\(result.stderr)"
        )
    }

    // MARK: - JSON envelope

    /// The apply document is `{"plan": ..., "result": ...}`. Exercised in-process because a
    /// real apply would install conda environments.
    func testApplyJSONEnvelopeCarriesBothPlanAndResult() throws {
        let plan = ReconciliationPlan(
            installEnvironments: [],
            reinstallEnvironments: [],
            removeEnvironments: [],
            databaseUpdates: [],
            pipelinePrefetch: [],
            bootstrapUpdate: nil,
            targetDependencySet: "2026.1",
            estimatedDownloadBytes: 0
        )
        let result = ReconciliationResult(
            succeeded: ["samtools"],
            failed: ["bracken": "boom"],
            receipt: DependencyReceipt(
                schemaVersion: DependencyReceipt.currentSchemaVersion,
                dependencySet: "2026.1",
                appVersion: "test",
                manifestHash: nil,
                updatedAt: Date(timeIntervalSince1970: 0),
                synthesized: false,
                environments: [:],
                databases: [:],
                pipelines: [:],
                bootstrap: nil
            )
        )

        let encoded = try ToolsCommand.UpdateSubcommand.encodeApplyJSON(plan: plan, result: result)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any]
        )

        let planObject = try XCTUnwrap(json["plan"] as? [String: Any])
        XCTAssertEqual(planObject["targetDependencySet"] as? String, "2026.1")

        let resultObject = try XCTUnwrap(json["result"] as? [String: Any])
        XCTAssertEqual(resultObject["succeeded"] as? [String], ["samtools"])
        XCTAssertEqual((resultObject["failed"] as? [String: String])?["bracken"], "boom")
    }

    // MARK: - Help registration

    func testToolsUpdateIsRegisteredOnTheRootCommand() throws {
        let result = try runCLI(["tools", "--help"], environment: [:])

        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("update"), "stdout:\n\(result.stdout)")
    }

    /// The exit codes are the scripting contract, so help has to state them.
    func testToolsUpdateHelpDocumentsTheExitCodes() throws {
        let result = try runCLI(["tools", "update", "--help"], environment: [:])

        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")
        for expected in ["Exit codes", "10", "nothing to do", "usage error", "failed"] {
            XCTAssertTrue(
                result.stdout.contains(expected),
                "help should mention '\(expected)':\n\(result.stdout)"
            )
        }
    }

    func testDbUpdateHelpDocumentsAllAndYes() throws {
        let result = try runCLI(["conda", "db", "update", "--help"], environment: [:])

        XCTAssertEqual(result.exitCode, 0, "stderr:\n\(result.stderr)")
        XCTAssertTrue(result.stdout.contains("--all"), "stdout:\n\(result.stdout)")
        XCTAssertTrue(result.stdout.contains("--yes"), "stdout:\n\(result.stdout)")
    }

    // MARK: - Helpers

    private func runCLI(
        _ arguments: [String],
        environment: [String: String]
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let binary = try XCTUnwrap(
            cliBinaryURL,
            "CLI binary not built at expected path - run `swift build --product lungfish-cli` before these process tests"
        )

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Both pipes are drained before waiting: a child that fills either 64KB buffer while
        // we block in waitUntilExit would deadlock.
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tools-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
