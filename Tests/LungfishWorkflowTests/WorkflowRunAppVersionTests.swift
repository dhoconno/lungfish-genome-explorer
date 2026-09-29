// WorkflowRunAppVersionTests.swift - The app identity recorded in provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class WorkflowRunAppVersionTests: XCTestCase {
    /// A bare `lungfish-cli` binary has no Info.plist version keys. The
    /// recorded identity must still carry the release version that
    /// `lungfish-cli --version` prints, never `Lungfish dev (0)`.
    func testMissingPlistVersionFallsBackToTheReleaseVersion() {
        let recorded = WorkflowRun.appVersion(infoDictionary: [:])
        XCTAssertEqual(recorded, "Lungfish \(LungfishAppVersion.short) (dev)")
        XCTAssertFalse(recorded.contains("dev (0)"))
        XCTAssertTrue(recorded.contains(LungfishAppVersion.short))
    }

    func testPackagedPlistVersionAndBuildAreRecordedVerbatim() {
        let recorded = WorkflowRun.appVersion(infoDictionary: [
            "CFBundleShortVersionString": "2026.9.99",
            "CFBundleVersion": "417",
        ])
        XCTAssertEqual(recorded, "Lungfish 2026.9.99 (417)")
    }

    func testBlankPlistValuesAreTreatedAsMissing() {
        let recorded = WorkflowRun.appVersion(infoDictionary: [
            "CFBundleShortVersionString": "  ",
            "CFBundleVersion": "",
        ])
        XCTAssertEqual(recorded, "Lungfish \(LungfishAppVersion.short) (dev)")
    }

    /// The identity every CLI envelope embeds derives from the same value.
    func testRuntimeIdentityUsesTheCurrentAppVersion() {
        let identity = ProvenanceRuntimeIdentity()
        XCTAssertEqual(identity.appVersion, WorkflowRun.currentAppVersion)
        XCTAssertTrue(identity.appVersion.contains(LungfishAppVersion.short) || identity.appVersion.hasPrefix("Lungfish "))
        XCTAssertNotEqual(identity.appVersion, "Lungfish dev (0)")
    }
    /// The packaged CLI's embedded identity plist has no version keys; its
    /// provenance must carry the enclosing app's release build, not `(dev)`.
    func testCLIInsideAnAppBundleRecordsTheAppBuild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-version-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("Lungfish Preview.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleShortVersionString": "2026.9.99", "CFBundleVersion": "5752"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let cli = macOS.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: cli.path, contents: Data())

        let enclosing = try XCTUnwrap(WorkflowRun.enclosingAppInfoDictionary(executableURL: cli))
        let recorded = WorkflowRun.appVersion(
            infoDictionary: ["CFBundleIdentifier": "com.lungfish.cli"],
            enclosingAppInfoDictionary: enclosing
        )
        XCTAssertEqual(recorded, "Lungfish 2026.9.99 (5752)")
        XCTAssertNil(WorkflowRun.enclosingAppInfoDictionary(executableURL: root.appendingPathComponent("lungfish-cli")))
    }
}
