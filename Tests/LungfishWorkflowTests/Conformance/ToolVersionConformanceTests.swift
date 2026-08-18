// ToolVersionConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Asserts that every tool the dependency manifest pins actually reports that
// pinned version when its version-check command runs against the local
// conda install. By default a missing tool or drifted pack-tool version is a
// skip (dev machines drift); with LUNGFISH_REQUIRE_TOOLS=1 both become hard
// failures so a conformance run can assert the full toolset is present and
// pinned.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class ToolVersionConformanceTests: XCTestCase {
    /// Every manifest tool env must report the manifest version from its version command.
    func testEveryManifestToolReportsPinnedVersion() async throws {
        let manifest = try ConformanceFixtures.manifest()
        var failures: [String] = []
        for tool in manifest.tools {
            let (exe, args) = ConformanceFixtures.versionCommand(for: tool.id)
            let url: URL
            do {
                url = try await CondaManager.shared.toolPath(name: exe, environment: tool.environment)
            } catch {
                if ToolAvailability.requireTools { failures.append("\(tool.id): not installed (\(exe) in env \(tool.environment)): \(error)") }
                continue
            }
            let r = try ProcessRunner.run(url, args, timeout: 60)
            if ConformanceFixtures.skipsVersionMatch(for: tool.id) {
                // Prints usage rather than a version string; a non-crash run (including
                // its typical non-zero "no args" exit) is the pass condition.
                continue
            }
            let text = r.stdout + r.stderr
            let expected = tool.version ?? ""
            if tool.id == "savont" {
                if !ConformanceFixtures.textReportsVersion(text, version: expected) {
                    let helpURL = url
                    let helpResult = try? ProcessRunner.run(helpURL, ["--help"], timeout: 60)
                    let helpText = (helpResult?.stdout ?? "") + (helpResult?.stderr ?? "")
                    if !ConformanceFixtures.textReportsVersion(helpText, version: expected) {
                        failures.append("\(tool.id): expected \(expected) in --version or --help output: \(text.prefix(200)) / \(helpText.prefix(200))")
                    }
                }
                continue
            }
            if !ConformanceFixtures.textReportsVersion(text, version: expected) {
                failures.append("\(tool.id): expected \(expected) in: \(text.prefix(200))")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testEveryInstalledPackToolReportsPinnedVersion() async throws {
        let manifest = try ConformanceFixtures.manifest()
        var failures: [String] = []
        var drifted: [String] = []
        for tool in manifest.packTools {
            let (exe, args) = ConformanceFixtures.versionCommand(for: tool.toolID)
            guard let url = try? await CondaManager.shared.toolPath(name: exe, environment: tool.environment) else { continue }
            let r = try ProcessRunner.run(url, args, timeout: 60)
            if ConformanceFixtures.skipsVersionMatch(for: tool.toolID) { continue }
            let text = r.stdout + r.stderr
            if !ConformanceFixtures.textReportsVersion(text, version: tool.version) {
                let message = "\(tool.toolID): expected \(tool.version) in: \(text.prefix(200))"
                if ToolAvailability.requireTools {
                    failures.append(message)
                } else {
                    drifted.append(message)
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        if !drifted.isEmpty {
            throw XCTSkip("pack tool version drift (run with LUNGFISH_REQUIRE_TOOLS=1 to enforce): \(drifted.joined(separator: "; "))")
        }
    }

    // MARK: - Version matcher

    /// `textReportsVersion` must anchor on a whole version token, not just any
    /// substring -- a short pin like "2.3" must not match inside "2.30", and
    /// an unrelated version elsewhere in the output must not match either.
    func testTextReportsVersionAnchorsOnWholeToken() {
        XCTAssertFalse(ConformanceFixtures.textReportsVersion("2.30", version: "2.3"))
        XCTAssertTrue(ConformanceFixtures.textReportsVersion("minimap2 2.30-r1287", version: "2.30"))
        XCTAssertFalse(ConformanceFixtures.textReportsVersion("bracken 3.0.1", version: "1.0.0"))
        XCTAssertTrue(ConformanceFixtures.textReportsVersion("samtools 1.23.1", version: "1.23.1"))
        XCTAssertTrue(ConformanceFixtures.textReportsVersion("cutadapt 5.2", version: "5.2"))
    }
}
