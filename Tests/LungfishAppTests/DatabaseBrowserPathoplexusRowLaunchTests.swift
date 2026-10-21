// DatabaseBrowserPathoplexusRowLaunchTests.swift - The route of the Pathoplexus browser's rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, panel decision C4. A Pathoplexus row runs `lungfish-cli fetch pathoplexus`. Lane
// A60 of 2.11 deleted the in-process route with its hidden key, and the key's test with it.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

final class DatabaseBrowserPathoplexusRowLaunchTests: XCTestCase {
    @MainActor
    func testTheArgumentsHoldTheOrganismAndNoKeyAndFollowTheGFF3Setting() {
        let folder = URL(fileURLWithPath: "/tmp/lane a45/Project.lungfish/Downloads", isDirectory: true)
        XCTAssertEqual(
            DatabaseBrowserViewModel.pathoplexusFetchArguments(
                accessions: ["PP_0012345"], organism: "mpox", folder: folder, includeGFF3Annotations: true),
            ["fetch", "pathoplexus", "PP_0012345", "--organism", "mpox", "--output-dir", folder.path, "--format", "json"])
        let withoutGFF3 = DatabaseBrowserViewModel.pathoplexusFetchArguments(
            accessions: ["PP_0012345"], organism: "mpox", folder: folder, includeGFF3Annotations: false)
        XCTAssertEqual(withoutGFF3, [
            "fetch", "pathoplexus", "PP_0012345", "--organism", "mpox", "--output-dir", folder.path, "--no-gff3",
            "--format", "json",
        ])
        XCTAssertFalse(withoutGFF3.contains("--api-key"))
        XCTAssertFalse(withoutGFF3.contains { $0.contains("lge-test-not-a-key") })
    }
}
