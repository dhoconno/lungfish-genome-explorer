// LungfishAppVersionBuildTests.swift - The build that records name beside the app version
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 B63 (SW12), BIO 4. `LungfishAppVersion.build` is the `<build>` of `Lungfish <version> (<build>)` in
// the records that LungfishIO and LungfishWorkflow write. It is read as `WorkflowRun.currentAppVersion` reads its
// build, and RunBundleAppIdentityTests in LungfishWorkflowTests pins the two to each other.

import XCTest
@testable import LungfishCore

final class LungfishAppVersionBuildTests: XCTestCase {
    private var packaged: [String: Any] {
        ["LungfishReleaseChannel": "stable", "CFBundleShortVersionString": "2026.9.99", "CFBundleVersion": "5752"]
    }

    /// The identity plist that a `lungfish-cli` embeds, which carries no version keys.
    private var embeddedCLI: [String: Any] { ["LungfishReleaseChannel": "stable"] }

    /// The Info.plist of a host such as xctest.
    private var host: [String: Any] { ["CFBundleShortVersionString": "16.0", "CFBundleVersion": "25228"] }

    func testAPackagedAppNamesItsOwnBuild() {
        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: packaged), "5752")
    }

    func testAPackagedCLITakesTheBuildOfTheAppThatHoldsIt() {
        XCTAssertEqual(
            LungfishAppVersion.resolveBuild(infoDictionary: embeddedCLI, enclosingAppInfoDictionary: packaged),
            "5752"
        )
    }

    func testABareCLIAndATestHostRecordDev() {
        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: embeddedCLI), "dev")
        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: host), "dev")
        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: host, enclosingAppInfoDictionary: host), "dev")
        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: [:]), "dev")
    }

    func testAHostLendsNothingButALungfishAppAroundItDoes() {
        XCTAssertEqual(
            LungfishAppVersion.resolveBuild(infoDictionary: host, enclosingAppInfoDictionary: packaged),
            "5752"
        )
    }

    /// A blank build, or one that is not text, lends nothing, and the next Lungfish plist may give one.
    func testABlankOrNonTextBuildIsSkipped() {
        for blank in ["", "  ", "\n"] {
            let info: [String: Any] = ["LungfishReleaseChannel": "stable", "CFBundleVersion": blank]
            XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: info), "dev", blank.debugDescription)
            XCTAssertEqual(
                LungfishAppVersion.resolveBuild(infoDictionary: info, enclosingAppInfoDictionary: packaged),
                "5752",
                blank.debugDescription
            )
        }
        let number: [String: Any] = ["LungfishReleaseChannel": "stable", "CFBundleVersion": 5752]
        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: number), "dev")
    }

    func testTheBuildIsTrimmed() {
        let info: [String: Any] = ["LungfishReleaseChannel": "stable", "CFBundleVersion": " 5752\n"]

        XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: info), "5752")
    }

    /// A fork's plist carries the other identity keys, and any one of the three makes a plist Lungfish's.
    func testAnyIdentityKeyMakesALungfishPlist() {
        for key in ["LungfishReleaseChannel", "LungfishRuntimeNamespace", "LungfishIdentitySchemaVersion"] {
            let info: [String: Any] = [key: "x", "CFBundleVersion": "9"]
            XCTAssertEqual(LungfishAppVersion.resolveBuild(infoDictionary: info), "9", key)
        }
    }

    /// `swift test` runs in xctest, which is not a Lungfish app, so a test run records `dev`.
    func testTheBuildOfATestProcessIsDev() {
        XCTAssertEqual(LungfishAppVersion.developmentBuild, "dev")
        XCTAssertEqual(LungfishAppVersion.build, "dev")
    }

    /// The Info.plist of the app that holds a CLI is read through the executable's real path, and only from
    /// `<name>.app/Contents/MacOS`.
    func testTheEnclosingAppPlistIsReadFromAnAppBundleOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-version-build-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Fixture.app/Contents", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for folder in [contents.appendingPathComponent("MacOS"), contents.appendingPathComponent("Resources"), bin] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: packaged, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let tool = contents.appendingPathComponent("MacOS/lungfish-cli")
        let resource = contents.appendingPathComponent("Resources/lungfish-cli")
        try Data().write(to: tool)
        try Data().write(to: resource)
        let link = bin.appendingPathComponent("lungfish-cli")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        XCTAssertEqual(LungfishAppVersion.enclosingAppInfoDictionary(executableURL: tool)?["CFBundleVersion"] as? String, "5752")
        XCTAssertEqual(LungfishAppVersion.enclosingAppInfoDictionary(executableURL: link)?["CFBundleVersion"] as? String, "5752")
        XCTAssertNil(LungfishAppVersion.enclosingAppInfoDictionary(executableURL: resource))
        XCTAssertNil(LungfishAppVersion.enclosingAppInfoDictionary(executableURL: bin.appendingPathComponent("plain")))
        XCTAssertNil(LungfishAppVersion.enclosingAppInfoDictionary(executableURL: nil))
    }
}
