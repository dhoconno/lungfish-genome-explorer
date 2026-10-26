// ToolTimeLimitTests.swift - An analysis tool run has no wall-clock limit unless its caller sets one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishWorkflow
import LungfishCore
import LungfishTestSupport

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. An analysis tool has no wall-clock limit by default,
/// and a limit is a named option that its caller sets. Each conda test reads the limit through
/// `CondaToolTimeLimit.specProbe`, so no test runs a tool for the length of a limit.
final class ToolTimeLimitTests: XCTestCase {

    // MARK: - CondaManager.runTool

    func testRunToolWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env")
        }

        XCTAssertEqual(limits, [nil], "runTool builds one launch, and with no timeout argument it carries no wall-clock limit")
    }

    func testRunToolWithAStdoutHandlerAndNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env", stdoutHandler: { _ in })
        }

        XCTAssertEqual(limits, [nil], "the streaming overload has its own default, and it carries no wall-clock limit")
    }

    func testRunToolKeepsTheLimitItsCallerSets() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env", timeout: 42)
        }

        XCTAssertEqual(limits, [.seconds(42)], "a caller that sets a limit keeps it")
    }

    // MARK: - Other analysis defaults

    func testGATKRunnersHaveNoWallClockLimitByDefault() {
        let manager = CondaManager(rootPrefix: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))

        XCTAssertNil(CondaFamilyProcess.limit(seconds: ManagedGATKCommandRunner(condaManager: manager).timeout),
                     "the managed GATK runner has no wall-clock limit unless its caller sets one")
        XCTAssertNil(CondaFamilyProcess.limit(seconds: ProcessGATKCommandRunner().timeout),
                     "the process GATK runner has no wall-clock limit unless its caller sets one")
    }

    /// The `timeout: TimeInterval = <seconds>` defaults that stay, each one a probe, a version check or an install.
    /// Any other default of that form in Workflow or CLI source is an analysis tool with a limit.
    private static let keptDefaults: [(file: String, line: String)] = [
        ("Sources/LungfishWorkflow/Variants/GATKInstalledToolVersion.swift", "timeout: TimeInterval = 60"), // version check
        ("Sources/LungfishWorkflow/Conda/ManagedToolSourceInstaller.swift", "timeout: TimeInterval = 30"), // runtime probe
        ("Sources/LungfishWorkflow/Conda/ManagedToolSourceInstaller.swift", "timeout: TimeInterval = 3_600"), // install step
        ("Sources/LungfishWorkflow/Engines/DockerRuntime.swift", "timeout: TimeInterval = 120.0"), // docker control command
        ("Sources/LungfishWorkflow/Native/ShellUtilities.swift", "timeout: TimeInterval = 30"), // version check
    ]

    func testNoAnalysisToolDeclaresAFiniteDefaultLimit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"timeout: TimeInterval = [0-9]"#)
        var offenders: [String] = []
        var seen = Set<String>()
        for folder in ["Sources/LungfishWorkflow", "Sources/LungfishCLI"] {
            for url in try repositoryFiles(under: root.appendingPathComponent(folder)) where url.pathExtension == "swift" {
                let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
                let lines = try readRepositorySource(url).components(separatedBy: "\n")
                for (index, raw) in lines.enumerated() {
                    let text = raw.trimmingCharacters(in: .whitespaces)
                    guard !text.hasPrefix("//"),
                          pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
                    let declaration = text.hasSuffix(",") ? String(text.dropLast()) : text
                    if Self.keptDefaults.contains(where: { $0.file == rel && $0.line == declaration }) {
                        seen.insert("\(rel) \(declaration)")
                    } else {
                        offenders.append("\(rel):\(index + 1): \(text)")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "An analysis tool has no wall-clock limit by default. Remove the default, or list it in keptDefaults with its reason:\n"
                      + offenders.joined(separator: "\n"))
        let stale = Self.keptDefaults.filter { !seen.contains("\($0.file) \($0.line)") }.map { "\($0.file) \($0.line)" }
        XCTAssertTrue(stale.isEmpty, "keptDefaults names a default that no longer exists:\n" + stale.joined(separator: "\n"))
    }

    // MARK: - Words of a stop by a limit

    func testCondaTimeLimitStopSaysWhatHappenedAndWhatToTry() {
        assertStoppedWords(CondaError.timeout(tool: "kraken2", seconds: 3600).errorDescription,
                           subject: "Tool 'kraken2'", after: "60 minutes")
        assertStoppedWords(CondaError.timeout(tool: "EsViritu", seconds: 7200).errorDescription,
                           subject: "Tool 'EsViritu'", after: "2 hours")
        assertStoppedWords(CondaError.timeout(tool: "samtools", seconds: 90).errorDescription,
                           subject: "Tool 'samtools'", after: "90 seconds")
    }

    func testGATKTimeLimitStopSaysWhatHappenedAndWhatToTry() {
        assertStoppedWords(ProcessGATKCommandRunnerError.timedOut(executable: "gatk", seconds: 7200).errorDescription,
                           subject: "gatk", after: "2 hours")
    }

    func testMappingSummaryTimeLimitStopSaysWhatHappenedAndWhatToTry() {
        assertStoppedWords(MappingSummaryBuilderError.samtoolsTimedOut(step: "samtools coverage", seconds: 1800).errorDescription,
                           subject: "samtools coverage", after: "30 minutes")
    }

    // MARK: - Helpers

    /// The words name what was stopped, after how long, that a time limit did it and what to try next.
    private func assertStoppedWords(_ words: String?, subject: String, after duration: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let words else { return XCTFail("the error has no words", file: file, line: line) }
        XCTAssertTrue(words.hasPrefix("\(subject) was stopped after \(duration) by its time limit."), words, file: file, line: line)
        XCTAssertTrue(words.hasSuffix("Run it again with no time limit or a longer one."), words, file: file, line: line)
    }

    /// The wall-clock limit of each launch that `call` makes, in launch order, nil for none.
    private func limitsOfLaunches(_ call: () async throws -> Void) async rethrows -> [Duration?] {
        let limits = OSAllocatedUnfairLock<[Duration?]>(initialState: [])
        try await CondaToolTimeLimit.$specProbe.withValue({ spec in
            limits.withLock { $0.append(spec.timeout) }
        }) { try await call() }
        return limits.withLock { $0 }
    }

    /// A manager whose micromamba is a script that reports a version, and for `run` prints a line and exits 0.
    private func makeScriptedManager() async throws -> (manager: CondaManager, sandbox: URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let bundledMicromamba = sandbox.appendingPathComponent("bundled-micromamba")
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "2.0.5-0"
                exit 0
                ;;
            run)
                echo "ok"
                exit 0
                ;;
            *)
                echo "unexpected args: $@" >&2
                exit 1
                ;;
        esac
        """
        try script.write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()
        return (manager, sandbox)
    }
}
