// DatabaseBrowserPathoplexusRowRouteTests.swift - The route of the Pathoplexus browser's rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, panel decision C4. A Pathoplexus row runs `lungfish-cli fetch pathoplexus` by
// default. A declared difference between the routes (the sequence's name on the INSDC way, the record
// the FASTA ways gain) keeps the in-process route behind a hidden key for one release, and each key
// value has a test.

import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishTestSupport

final class DatabaseBrowserPathoplexusRowRouteTests: XCTestCase {
    func testTheHiddenKeyPicksTheRoute() {
        let suite = makeTestDefaultsSuite(prefix: "pathoplexus-row-route")
        let settings = PathoplexusRowDownloadRouteSettings(defaults: suite.defaults)
        XCTAssertEqual(PathoplexusRowDownloadRouteSettings.defaultRoute, .cli, "the flip: the CLI route is the default")
        XCTAssertEqual(settings.route, .cli, "an unset key")
        let cases: [(Any, PathoplexusRowDownloadRoute)] = [
            ("cli", .cli), ("legacy", .legacy), ("LEGACY", .legacy), (true, .cli), (false, .legacy),
            ("NO", PathoplexusRowDownloadRouteSettings.defaultRoute),
        ]
        for (value, route) in cases {
            suite.defaults.set(value, forKey: PathoplexusRowDownloadRouteSettings.defaultsKey)
            XCTAssertEqual(settings.route, route, "\(value)")
        }
    }

    func testTheKeyIsNotTheOtherRowsKeys() {
        XCTAssertNotEqual(PathoplexusRowDownloadRouteSettings.defaultsKey, NucleotideRowDownloadRouteSettings.defaultsKey)
    }

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
