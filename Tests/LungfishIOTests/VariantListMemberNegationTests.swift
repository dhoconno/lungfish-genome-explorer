// VariantListMemberNegationTests.swift - An inequality on a list-valued INFO key is the complement of the member match
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishIO

/// Lane 13.37, decision MD53 item 2. `!=` on an `ANN_`, `CSQ_` or impact key keeps a variant none of whose list members
/// equals the value, so a variant that `=` keeps is never kept by `!=` with the same value.
final class VariantListMemberNegationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "list-member-negation")
    }

    override func tearDownWithError() throws {
        if let directory { TestTempDirectory.cleanup(directory) }
    }

    func testInequalityOnAListKeyIsTheComplementOfTheMemberMatchAtEveryProfile() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                VariantListMemberCaseTests.listMemberVCF, profile: profile, in: directory, name: "negation")
            let database = try VariantDatabase(url: dbURL)
            func hits(_ key: String, _ op: VariantDatabase.InfoFilter.ComparisonOp, _ value: String) -> [Int] {
                let filter = VariantDatabase.InfoFilter(key: key, op: op, value: value)
                return database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
            }
            // POS 100 holds the impacts HIGH and MODERATE, POS 200 holds a lone MODERATE.
            XCTAssertEqual(hits("ANN_IMPACT", .eq, "HIGH"), [100], "= HIGH \(profile)")
            XCTAssertEqual(hits("ANN_IMPACT", .neq, "HIGH"), [200], "!= HIGH \(profile)")
            XCTAssertEqual(hits("ANN_IMPACT", .eq, "MODERATE"), [100, 200], "= MODERATE \(profile)")
            XCTAssertEqual(hits("ANN_IMPACT", .neq, "MODERATE"), [], "!= MODERATE \(profile)")
            // The members compare in their own case, so `high` is no member and `!=` keeps both variants.
            XCTAssertEqual(hits("ANN_IMPACT", .neq, "high"), [100, 200], "!= high \(profile)")
            XCTAssertEqual(hits("ANN_Gene", .neq, "w"), [200], "!= w \(profile)")
            XCTAssertEqual(hits("ANN_Gene", .neq, "W"), [100], "!= W \(profile)")
            // A key that holds no list keeps the whole-value comparison.
            XCTAssertEqual(hits("DP", .neq, "40"), [200], "DP != 40 \(profile)")
        }
    }
}
