// HaplotypeToolVersionBuildTests.swift - The build that a haplotype definition record names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 B63 (SW12), BIO 4. A haplotype definition record names `Lungfish <version> (<build>)`. Its version
// is Lungfish's own, and its build came from `Bundle.main`, so a test host or a packaged CLI wrote its host's
// build, or `0` when the host has none. That is a false fact in a record.

import XCTest
import LungfishCore
import LungfishIO

final class HaplotypeToolVersionBuildTests: XCTestCase {
    /// Pin at the base. This passes today and B63 M2 replaces it. In a test host the build of the record is the
    /// host's `CFBundleVersion`, or `0` when the host has none, and it is never Lungfish's `dev`.
    func testTheHaplotypeRecordBuildIsTheHostsToday() {
        let hostBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let toolVersion = HaplotypeDefinitionStore.currentToolVersion
        print("B63 M1 pin: host build \(hostBuild.debugDescription), record \(toolVersion.debugDescription)")

        XCTAssertEqual(toolVersion, "Lungfish \(LungfishAppVersion.short) (\(hostBuild))")
        XCTAssertNotEqual(hostBuild, "dev")
    }
}
