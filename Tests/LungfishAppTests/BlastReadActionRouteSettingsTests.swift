// BlastReadActionRouteSettingsTests.swift - The hidden key of the viewers' BLAST read actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A65 M2, review fix F3 (C4, ARCH 7). `BlastReadActionRoute` is the hidden key that keeps
// the in-process search for one release. The default is the CLI route, so a person who never sets the key
// runs `lungfish-cli blast submit`. The reader takes a string (`cli` or `legacy`, in any case) or a Boolean
// that is true for the CLI route, and keeps the default for anything else. The test reads a defaults suite
// of its own, so nothing touches `UserDefaults.standard` and no plist reaches `~/Library/Preferences`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishTestSupport

@MainActor
final class BlastReadActionRouteSettingsTests: XCTestCase {
    func testTheKeyPicksTheRouteAndAnythingElseKeepsTheDefault() {
        XCTAssertEqual(BlastReadActionRouteSettings.defaultsKey, "BlastReadActionRoute")
        XCTAssertEqual(BlastReadActionRouteSettings.defaultRoute, .cli, "the CLI route is the default (C4)")
        let defaults = makeTestDefaultsSuite(prefix: "BlastReadActionRouteSettingsTests").defaults
        let settings = BlastReadActionRouteSettings(defaults: defaults)
        XCTAssertEqual(settings.route, .cli, "an unset key takes the default")

        // A value the reader does not know, such as "junk", reads the default, the CLI route.
        let cases: [(Any, BlastReadActionRoute)] = [
            ("legacy", .legacy), ("LEGACY", .legacy), ("cli", .cli), ("Cli", .cli), ("junk", .cli),
            (false, .legacy), (true, .cli),
        ]
        for (value, route) in cases {
            defaults.set(value, forKey: BlastReadActionRouteSettings.defaultsKey)
            XCTAssertEqual(settings.route, route, "\(value)")
        }
        defaults.removeObject(forKey: BlastReadActionRouteSettings.defaultsKey)
        XCTAssertEqual(settings.route, .cli, "an unset key reads the default again")
    }
}
