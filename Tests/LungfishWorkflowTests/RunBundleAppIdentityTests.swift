// RunBundleAppIdentityTests.swift - The app identity that run bundles and haplotype edits record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 FXS34, BIO's finding on FX46. Three writers took the app version from `Bundle.main`. A test run
// recorded its host's version (xctest's own), and a packaged `lungfish-cli` recorded none, since its embedded
// plist carries no version keys. NFCoreRunBundleManifestTests covers the nf-core manifest. This suite covers the
// other two writers.
//
// Phase 2.11 B63 (SW12), BIO 4. The build of the haplotype record came from `Bundle.main`, and the manifests took
// theirs from a helper in this module. `LungfishAppVersion.build` in LungfishCore is now the one value all three
// read. `WorkflowRun.appVersion` keeps its own read of the same rule, so this suite pins the two to each other.

import XCTest
@testable import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class RunBundleAppIdentityTests: XCTestCase {
    /// The manifest of a local workflow run names Lungfish's version and build, and the two make the identity a
    /// run record names for the same process.
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
        XCTAssertEqual(manifest.appBuildVersion, LungfishAppVersion.build)
        XCTAssertEqual(
            "Lungfish \(LungfishAppVersion.short) (\(LungfishAppVersion.build))",
            WorkflowRun.currentAppVersion
        )
    }

    /// The tool version of a haplotype definition edit is the identity that a run record names for the same
    /// process, build included.
    func testTheHaplotypeToolVersionIsTheIdentityOfARunRecord() {
        XCTAssertEqual(HaplotypeDefinitionStore.currentToolVersion, WorkflowRun.currentAppVersion)
    }

    /// The build of LungfishCore and the build in a run record are one rule. A Lungfish Info.plist lends its
    /// build, the app that holds a CLI lends it to the CLI, and a host's lends none.
    func testTheCoreBuildIsTheBuildARunRecordNames() {
        let packaged: [String: Any] = [
            "LungfishReleaseChannel": "stable", "CFBundleShortVersionString": "2026.9.99", "CFBundleVersion": "5752",
        ]
        let embeddedCLI: [String: Any] = ["LungfishReleaseChannel": "stable"]
        let host: [String: Any] = ["CFBundleShortVersionString": "16.0", "CFBundleVersion": "25228"]
        let blank: [String: Any] = ["LungfishReleaseChannel": "stable", "CFBundleVersion": "  "]
        let fork: [String: Any] = ["LungfishRuntimeNamespace": "org.example.fork", "CFBundleVersion": "9"]
        let cases: [(label: String, info: [String: Any], enclosing: [String: Any]?, expected: String)] = [
            ("packaged app", packaged, nil, "5752"),
            ("packaged CLI", embeddedCLI, packaged, "5752"),
            ("bare CLI", embeddedCLI, nil, "dev"),
            ("test host", host, nil, "dev"),
            ("test host inside a Lungfish app", host, packaged, "5752"),
            ("blank build", blank, nil, "dev"),
            ("blank build, then the app", blank, packaged, "5752"),
            ("fork", fork, nil, "9"),
        ]

        for testCase in cases {
            let core = LungfishAppVersion.resolveBuild(
                infoDictionary: testCase.info, enclosingAppInfoDictionary: testCase.enclosing
            )
            let run = WorkflowRun.appVersion(
                infoDictionary: testCase.info, enclosingAppInfoDictionary: testCase.enclosing
            )
            XCTAssertEqual(core, testCase.expected, testCase.label)
            XCTAssertEqual(Self.build(inAppVersion: run), core, "\(testCase.label): \(run)")
        }
    }

    /// `5752` from `Lungfish 2026.9.99 (5752)`.
    private static func build(inAppVersion appVersion: String) -> String {
        guard appVersion.hasSuffix(")"), let open = appVersion.lastIndex(of: "(") else { return appVersion }
        return String(appVersion[appVersion.index(after: open)..<appVersion.index(before: appVersion.endIndex)])
    }
}
