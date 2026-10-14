// WorkflowRunAppVersionTests.swift - The app identity recorded in provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishWorkflow

final class WorkflowRunAppVersionTests: XCTestCase {
    /// The Preview app's Info.plist as release packaging stamps it: `Lungfish-Info.plist` with
    /// the identifier and channel `scripts/release/build-notarized-dmg.sh` sets.
    private static var previewAppInfo: [String: Any] {
        previewCLIIdentityInfo.merging(["CFBundleShortVersionString": "2026.9.99", "CFBundleVersion": "5752"]) { $1 }
    }

    /// The identity plist the Preview app's `lungfish-cli` embeds, `LungfishCLI-Info.plist`,
    /// which holds no version keys.
    private static var previewCLIIdentityInfo: [String: Any] {
        [
            "CFBundleIdentifier": LungfishAppIdentity.preview.bundleIdentifier,
            "CFBundleName": LungfishAppIdentity.preview.shortName,
            "CFBundleDisplayName": LungfishAppIdentity.preview.fullName,
            "LungfishReleaseChannel": LungfishReleaseChannel.preview.rawValue,
        ]
    }

    /// The bundle and version keys of xctest's own Info.plist, which `Bundle.main` reads in a
    /// test run (`otool -P` of Xcode's `usr/bin/xctest`).
    private static var xctestInfo: [String: Any] {
        [
            "CFBundleIdentifier": "com.apple.dt.xctest.tool",
            "CFBundleExecutable": "xctest",
            "CFBundleName": "xctest",
            "CFBundleShortVersionString": "16.0",
            "CFBundleVersion": "25228",
        ]
    }

    /// A host that is not Lungfish, such as xctest, lends no version, so a test run records
    /// what a bare `lungfish-cli` records. A Lungfish app, and the CLI it bundles, still record
    /// the app's version and build (2.10 A42 fix, the manager's ruling on Fix 4).
    func testOnlyALungfishInfoPlistLendsItsVersionAndBuild() {
        let bareCLI = "Lungfish \(LungfishAppVersion.short) (dev)"
        XCTAssertEqual(WorkflowRun.appVersion(infoDictionary: Self.xctestInfo), bareCLI)
        XCTAssertEqual(
            WorkflowRun.appVersion(infoDictionary: Self.previewCLIIdentityInfo, enclosingAppInfoDictionary: Self.xctestInfo),
            bareCLI
        )
        XCTAssertEqual(WorkflowRun.appVersion(infoDictionary: Self.previewAppInfo), "Lungfish 2026.9.99 (5752)")
        XCTAssertEqual(
            WorkflowRun.appVersion(infoDictionary: Self.previewCLIIdentityInfo, enclosingAppInfoDictionary: Self.previewAppInfo),
            "Lungfish 2026.9.99 (5752)"
        )
    }

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
        var info = Self.previewAppInfo
        info["CFBundleVersion"] = "417"
        let recorded = WorkflowRun.appVersion(infoDictionary: info)
        XCTAssertEqual(recorded, "Lungfish 2026.9.99 (417)")
    }

    func testBlankPlistValuesAreTreatedAsMissing() {
        var info = Self.previewCLIIdentityInfo
        info["CFBundleShortVersionString"] = "  "
        info["CFBundleVersion"] = ""
        let recorded = WorkflowRun.appVersion(infoDictionary: info)
        XCTAssertEqual(recorded, "Lungfish \(LungfishAppVersion.short) (dev)")
    }

    /// The identity every CLI envelope embeds derives from the same value.
    func testRuntimeIdentityUsesTheCurrentAppVersion() {
        let identity = ProvenanceRuntimeIdentity()
        XCTAssertEqual(identity.appVersion, WorkflowRun.currentAppVersion)
        XCTAssertTrue(identity.appVersion?.contains(LungfishAppVersion.short) == true || identity.appVersion?.hasPrefix("Lungfish ") == true)
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
        try PropertyListSerialization.data(fromPropertyList: Self.previewAppInfo, format: .xml, options: 0)
            .write(to: macOS.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let cli = macOS.appendingPathComponent("lungfish-cli")
        FileManager.default.createFile(atPath: cli.path, contents: Data())

        let enclosing = try XCTUnwrap(WorkflowRun.enclosingAppInfoDictionary(executableURL: cli))
        let recorded = WorkflowRun.appVersion(
            infoDictionary: Self.previewCLIIdentityInfo,
            enclosingAppInfoDictionary: enclosing
        )
        XCTAssertEqual(recorded, "Lungfish 2026.9.99 (5752)")
        XCTAssertNil(WorkflowRun.enclosingAppInfoDictionary(executableURL: root.appendingPathComponent("lungfish-cli")))
    }
}
