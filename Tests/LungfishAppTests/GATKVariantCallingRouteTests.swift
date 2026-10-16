// GATKVariantCallingRouteTests.swift - The hidden key of the Call Variants dialog's GATK row
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A50 M3 (decision C4 of Phase 2.10, ARCH memo N4 and check 7, QA 6). The key reads its
// own defaults through its own settings type. Each test gives it a suite of its own, which teardown
// removes, and never touches the user's defaults.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishApp

final class GATKVariantCallingRouteTests: XCTestCase {
    /// The route a suite holding `value` under the key gives, or none when `value` is nil.
    private func route(for value: Any?) -> GATKVariantCallingRoute {
        let suite = makeTestDefaultsSuite(prefix: "gatk-variant-calling-route")
        if let value {
            suite.defaults.set(value, forKey: GATKVariantCallingRouteSettings.defaultsKey)
        }
        return GATKVariantCallingRouteSettings(defaults: suite.defaults).route
    }

    func testTheKeyIsNamedForTheGATKRow() {
        XCTAssertEqual(GATKVariantCallingRouteSettings.defaultsKey, "GATKVariantCallingRoute")
    }

    func testAnUnsetKeyTakesTheDefaultRoute() {
        XCTAssertEqual(route(for: nil), GATKVariantCallingRouteSettings.defaultRoute)
    }

    func testTheValueCLITakesTheLeafOnTheRunner() {
        XCTAssertEqual(route(for: "cli"), .cli)
        XCTAssertEqual(route(for: "CLI"), .cli)
        XCTAssertEqual(route(for: true), .cli)
    }

    func testTheValueLegacyKeepsTheInProcessRun() {
        XCTAssertEqual(route(for: "legacy"), .legacy)
        XCTAssertEqual(route(for: "Legacy"), .legacy)
        XCTAssertEqual(route(for: false), .legacy)
    }

    func testAValueTheReaderDoesNotKnowTakesTheDefaultRoute() {
        XCTAssertEqual(route(for: "sideways"), GATKVariantCallingRouteSettings.defaultRoute)
        XCTAssertEqual(route(for: 7), GATKVariantCallingRouteSettings.defaultRoute)
    }

    /// ARCH check 7 and C4. The key defaults to `legacy` until the lane's last commit sets it to `cli`.
    func testTheDefaultRouteIsTheInProcessRunUntilTheLastCommit() {
        XCTAssertEqual(GATKVariantCallingRouteSettings.defaultRoute, .legacy)
    }
}
