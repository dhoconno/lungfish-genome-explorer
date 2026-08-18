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
    /// Pack tools whose pinned arm64 build cannot report its own version, and
    /// whose installed version is therefore asserted against conda-meta.
    ///
    /// Deliberately narrow: every entry is a named upstream packaging defect
    /// documented at the use site. Nothing else may weaken its version check.
    static let selfReportedVersionIsUnreliable: Set<String> = ["bwa-mem2", "bracken"]

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

            // UPSTREAM PACKAGING DEFECTS: two pinned arm64 builds cannot report
            // their own version, so for these -- and only these -- the installed
            // version is asserted against the environment's conda-meta record
            // instead of the self-reported string.
            //
            //   * bwa-mem2 (`bioconda::bwa-mem2=2.3=hda5e58c_0`): `bwa-mem2
            //     version` prints "2.2.1". The build ships 2.3 binaries but was
            //     packaged with a stale version string.
            //   * bracken (`bioconda::bracken=1.0.0=1`): the package ships no
            //     driver at all, only `est_abundance.py` and friends, so
            //     `CondaManager.ensureBrackenLauncher` synthesizes `bin/bracken`
            //     as a passthrough to that script, which has no version flag.
            //     `bracken -v` therefore prints an argparse usage error. This one
            //     is not an upstream defect and no re-pin can fix it; see
            //     BrackenInvocationForm.swift. An environment that does have a
            //     real Bracken driver reports its version normally, and this
            //     branch simply confirms conda-meta agrees with the pin.
            //
            // In both cases conda-meta records the correct version and no newer
            // arm64 build exists. This stays a hard assertion: if conda-meta ever
            // disagrees with the manifest pin, it fails loudly. REMOVE the
            // bwa-mem2 entry once a fixed arm64 build is pinned.
            //
            // Like the self-reported path below, a mismatch is a hard failure
            // only under LUNGFISH_REQUIRE_TOOLS=1; on a drifting dev machine it
            // reports as drift, so this exception never turns a tolerated skip
            // into a failure.
            if Self.selfReportedVersionIsUnreliable.contains(tool.toolID) {
                let envURL = await CondaManager.shared.environmentURL(named: tool.environment)
                let meta = CondaMetaReader.primaryPackage(named: tool.toolID, inEnvironment: envURL)
                let message: String?
                if let meta {
                    message = meta.version == tool.version
                        ? nil
                        : "\(tool.toolID): conda-meta version \(meta.version) does not match manifest pin \(tool.version)"
                } else {
                    message = "\(tool.toolID): no conda-meta record in env \(tool.environment)"
                }
                if let message {
                    if ToolAvailability.requireTools {
                        failures.append(message)
                    } else {
                        drifted.append(message)
                    }
                }
                continue
            }

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

    /// The conda-meta exception must stay narrow, and each excepted tool must
    /// actually be pinned by the manifest -- a stale entry would silently stop
    /// checking a tool that has since been fixed or removed.
    func testConfirmedVersionExceptionsStayNarrowAndPinned() throws {
        let manifest = try ConformanceFixtures.manifest()
        let packToolIDs = Set(manifest.packTools.map(\.toolID))
        for excepted in Self.selfReportedVersionIsUnreliable {
            XCTAssertTrue(
                packToolIDs.contains(excepted),
                "\(excepted) is excepted from self-reported version checks but is no longer a pinned pack tool; remove the exception"
            )
        }
        XCTAssertEqual(
            Self.selfReportedVersionIsUnreliable, ["bwa-mem2", "bracken"],
            "adding a tool here weakens its version assertion; document the upstream defect first"
        )
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
