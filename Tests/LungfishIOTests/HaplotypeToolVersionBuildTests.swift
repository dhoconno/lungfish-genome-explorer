// HaplotypeToolVersionBuildTests.swift - The build that a haplotype definition record names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 B63 (SW12), BIO 4. A haplotype definition record names `Lungfish <version> (<build>)`. Its version
// is Lungfish's own, and its build came from `Bundle.main`, so a test host or a packaged CLI wrote its host's
// build, or `0` when the host has none. That is a false fact in a record. The record now reads
// `LungfishAppVersion.build`, which is `dev` when no Lungfish Info.plist gives a build.

import XCTest
import LungfishCore
import LungfishIO

final class HaplotypeToolVersionBuildTests: XCTestCase {
    /// The record names Lungfish's own version and build. A test host is not Lungfish, so its build is `dev`.
    func testTheHaplotypeRecordNamesTheAppsOwnBuild() {
        XCTAssertEqual(LungfishAppVersion.build, "dev")
        XCTAssertEqual(
            HaplotypeDefinitionStore.currentToolVersion,
            "Lungfish \(LungfishAppVersion.short) (\(LungfishAppVersion.build))"
        )
    }

    /// The pin of B63 M1 read the host's build, `25229` under xctest, and `0` for a host without one. The record
    /// says neither now.
    func testTheHaplotypeRecordNeverNamesTheHostsBuildOrZero() {
        let hostBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let toolVersion = HaplotypeDefinitionStore.currentToolVersion

        XCTAssertFalse(toolVersion.hasSuffix(" (\(hostBuild))"), toolVersion)
        XCTAssertFalse(toolVersion.hasSuffix(" (0)"), toolVersion)
    }
}
