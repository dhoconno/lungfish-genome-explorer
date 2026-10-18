// ClassifierBlastRouteSettingsTests.swift - The hidden key of the classifier BLAST Verify actions on blast submit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.08 (C4, R-A1, U-R1, ARCH 7). `ClassifierBlastRoute` keeps the in-process search of the NVD and
// EsViritu BLAST Verify actions, and of the TaxTriage, 12S and Kraken2 ones that lanes 12.09 and 12.10 move, for one
// release. The default is the CLI route, so a person who never sets the key runs `lungfish-cli blast submit`. The
// reader takes a string (`cli` or `legacy`, in any case) or a Boolean that is true for the CLI route, and keeps the
// default for anything else. The test reads a defaults suite of its own, so nothing touches `UserDefaults.standard`
// and no plist reaches `~/Library/Preferences`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class ClassifierBlastRouteSettingsTests: XCTestCase {
    func testTheKeyPicksTheRouteAndAnythingElseKeepsTheDefault() {
        XCTAssertEqual(ClassifierBlastRouteSettings.defaultsKey, "ClassifierBlastRoute")
        XCTAssertNotEqual(ClassifierBlastRouteSettings.defaultsKey, "BlastReadActionRoute", "a key name is never reused (U-R1)")
        XCTAssertEqual(ClassifierBlastRouteSettings.defaultRoute, .cli, "the CLI route is the default (C4)")
        let defaults = makeTestDefaultsSuite(prefix: "ClassifierBlastRouteSettingsTests").defaults
        let settings = ClassifierBlastRouteSettings(defaults: defaults)
        XCTAssertEqual(settings.route, .cli, "an unset key takes the default")

        // A value the reader does not know, such as "junk", reads the default, the CLI route.
        let cases: [(Any, ClassifierBlastRoute)] = [
            ("legacy", .legacy), ("LEGACY", .legacy), ("cli", .cli), ("Cli", .cli), ("junk", .cli),
            (false, .legacy), (true, .cli),
        ]
        for (value, route) in cases {
            defaults.set(value, forKey: ClassifierBlastRouteSettings.defaultsKey)
            XCTAssertEqual(settings.route, route, "\(value)")
        }
        defaults.removeObject(forKey: ClassifierBlastRouteSettings.defaultsKey)
        XCTAssertEqual(settings.route, .cli, "an unset key reads the default again")
    }
}
