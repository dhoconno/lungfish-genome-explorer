// RunBundleAppIdentityTests.swift - The app identity that run bundles and haplotype edits record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 FXS34, BIO's finding on FX46. Three writers took the app version from `Bundle.main`. A test run
// recorded its host's version (xctest's own), and a packaged `lungfish-cli` recorded none, since its embedded
// plist carries no version keys. NFCoreRunBundleManifestTests covers the nf-core manifest. This suite covers the
// other two writers.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class RunBundleAppIdentityTests: XCTestCase {
    /// The manifest of a local workflow run names Lungfish's version, and its build is the one a run record names
    /// for the same process.
    func testTheLocalManifestNamesTheAppVersionNotTheHosts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-app-identity-\(UUID().uuidString)", isDirectory: true)
        let request = LocalWorkflowRunRequest(
            workflowURL: root.appendingPathComponent("Fixture.lungfishflowpkg/main.nf"),
            engine: .nextflow,
            inputURLs: [root.appendingPathComponent("input.txt")],
            outputDirectory: root.appendingPathComponent("results"),
            params: [:]
        )

        let manifest = request.manifest()

        XCTAssertEqual(manifest.appVersion, LungfishAppVersion.short)
        let build = try XCTUnwrap(manifest.appBuildVersion)
        XCTAssertEqual("Lungfish \(LungfishAppVersion.short) (\(build))", WorkflowRun.currentAppVersion)
    }

    /// The tool version of a haplotype definition edit names Lungfish's version. LungfishIO cannot see
    /// `WorkflowRun`, so its build is not pinned here.
    func testTheHaplotypeToolVersionNamesTheAppVersionNotTheHosts() {
        let toolVersion = HaplotypeDefinitionStore.currentToolVersion

        XCTAssertTrue(toolVersion.hasPrefix("Lungfish \(LungfishAppVersion.short) ("), toolVersion)
    }

    /// The build is read out of the app identity a run record carries, so a manifest and its record agree. A
    /// Lungfish Info.plist lends its build, and a host's lends none.
    func testTheBuildIsTheOneAnAppVersionNames() {
        XCTAssertEqual(RunBundleAppBuild.build(inAppVersion: "Lungfish 2026.9.99 (5752)"), "5752")
        XCTAssertEqual(RunBundleAppBuild.build(inAppVersion: "Lungfish 2026.10.10 (dev)"), "dev")
        for unreadable in ["Lungfish 2026.9.99 ( )", "Lungfish 2026.9.99", ""] {
            XCTAssertEqual(RunBundleAppBuild.build(inAppVersion: unreadable), "dev", unreadable.debugDescription)
        }

        let packaged = WorkflowRun.appVersion(infoDictionary: [
            "LungfishReleaseChannel": "stable", "CFBundleShortVersionString": "2026.9.99", "CFBundleVersion": "5752",
        ])
        XCTAssertEqual(RunBundleAppBuild.build(inAppVersion: packaged), "5752")
        let host = WorkflowRun.appVersion(infoDictionary: ["CFBundleShortVersionString": "16.0", "CFBundleVersion": "25228"])
        XCTAssertEqual(RunBundleAppBuild.build(inAppVersion: host), "dev")
    }
}
