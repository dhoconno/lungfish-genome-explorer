// AlignmentFilterCommandBuilderTests.swift - Tests for BAM filter command planning
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp

final class AlignmentFilterCommandBuilderTests: XCTestCase {

    func testBuildCombinesMappedPrimaryDuplicateExcludedAndExactMatchFilters() throws {
        let request = AlignmentFilterRequest(
            mappedOnly: true,
            primaryOnly: true,
            minimumMAPQ: 30,
            duplicateMode: .exclude,
            identityFilter: .exactMatch,
            region: "chr7"
        )

        let plan = try AlignmentFilterCommandBuilder.build(from: request)

        XCTAssertEqual(plan.executable, "samtools")
        XCTAssertEqual(plan.subcommand, "view")
        XCTAssertEqual(plan.arguments, [
            "-b",
            "-F", "0xD04",
            "-q", "30",
            "-e", "[NM] == 0"
        ])
        XCTAssertEqual(plan.trailingArguments, ["chr7"])
        XCTAssertEqual(
            plan.commandArguments(appendingInputPath: "/tmp/input.bam"),
            [
                "view",
                "-b",
                "-F", "0xD04",
                "-q", "30",
                "-e", "[NM] == 0",
                "/tmp/input.bam",
                "chr7"
            ]
        )
        XCTAssertTrue(plan.preprocessingSteps.isEmpty)
        XCTAssertEqual(plan.duplicateMode, .exclude)
        XCTAssertEqual(plan.identityFilterExpression, "[NM] == 0")
        XCTAssertEqual(plan.requiredSAMTags, ["NM"])
    }

    func testBuildUsesPercentIdentityExpressionBasedOnAlignedQueryBasesAfterDuplicateMarking() throws {
        let request = AlignmentFilterRequest(
            mappedOnly: false,
            primaryOnly: false,
            minimumMAPQ: nil,
            duplicateMode: .remove,
            identityFilter: .minimumPercentIdentity(95),
            region: nil
        )

        let plan = try AlignmentFilterCommandBuilder.build(from: request)

        XCTAssertEqual(plan.arguments, [
            "-b",
            "-F", "0x400",
            "-e", "(qlen > sclen) && (((qlen - sclen - [NM]) / (qlen - sclen)) * 100 >= 95)"
        ])
        XCTAssertTrue(plan.trailingArguments.isEmpty)
        XCTAssertEqual(plan.duplicateMode, .remove)
        XCTAssertEqual(plan.preprocessingSteps, [.samtoolsMarkdup(removeDuplicates: false)])
        XCTAssertEqual(
            plan.identityFilterExpression,
            "(qlen > sclen) && (((qlen - sclen - [NM]) / (qlen - sclen)) * 100 >= 95)"
        )
        XCTAssertEqual(plan.requiredSAMTags, ["NM"])
    }

    func testBuildRejectsNegativeMinimumMAPQ() {
        let request = AlignmentFilterRequest(minimumMAPQ: -1)

        XCTAssertThrowsError(try AlignmentFilterCommandBuilder.build(from: request)) { error in
            XCTAssertEqual(error as? AlignmentFilterError, .invalidMinimumMAPQ(-1))
        }
    }

    func testBuildRejectsBlankRegion() {
        let request = AlignmentFilterRequest(region: "   ")

        XCTAssertThrowsError(try AlignmentFilterCommandBuilder.build(from: request)) { error in
            XCTAssertEqual(error as? AlignmentFilterError, .invalidRegion("   "))
        }
    }

    func testBuildRejectsOutOfRangeMinimumPercentIdentity() {
        let request = AlignmentFilterRequest(identityFilter: .minimumPercentIdentity(100.1))

        XCTAssertThrowsError(try AlignmentFilterCommandBuilder.build(from: request)) { error in
            XCTAssertEqual(error as? AlignmentFilterError, .invalidMinimumPercentIdentity(100.1))
        }
    }

    func testBuildFormatsDecimalPercentIdentityThresholdWithoutTrailingZeros() throws {
        let request = AlignmentFilterRequest(identityFilter: .minimumPercentIdentity(97.5))

        let plan = try AlignmentFilterCommandBuilder.build(from: request)

        XCTAssertEqual(
            plan.identityFilterExpression,
            "(qlen > sclen) && (((qlen - sclen - [NM]) / (qlen - sclen)) * 100 >= 97.5)"
        )
    }

    func testBuildRecordsRequiredTagsForIdentityFilters() throws {
        let request = AlignmentFilterRequest(identityFilter: .exactMatch)

        let plan = try AlignmentFilterCommandBuilder.build(from: request)

        XCTAssertEqual(plan.requiredSAMTags, ["NM"])
    }
}
