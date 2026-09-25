// EsVirituReadLengthWarningTests.swift - EsViritu dialog short-read warning text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishWorkflow

final class EsVirituReadLengthWarningTests: XCTestCase {

    func testNoAdvisoriesGiveNoWarning() {
        XCTAssertNil(EsVirituReadLengthWarning.make(advisories: [:], sampleOrder: ["A"]))
    }

    func testSingleSampleUsesAdvisoryWording() throws {
        let warning = try XCTUnwrap(EsVirituReadLengthWarning.make(
            advisories: ["SRR12486983": .allReadsTooShort(maxReadLength: 76)],
            sampleOrder: ["SRR12486983"]
        ))
        XCTAssertTrue(warning.isSevere)
        XCTAssertEqual(warning.message, EsVirituReadLengthAdvisory.allReadsTooShort(maxReadLength: 76).wizardMessage)
    }

    func testSingleSampleSoftWarning() throws {
        let warning = try XCTUnwrap(EsVirituReadLengthWarning.make(
            advisories: ["S": .mostReadsTooShort(medianReadLength: 90, maxReadLength: 151)],
            sampleOrder: ["S"]
        ))
        XCTAssertFalse(warning.isSevere)
    }

    func testBatchListsAffectedSamples() throws {
        let warning = try XCTUnwrap(EsVirituReadLengthWarning.make(
            advisories: [
                "A": .allReadsTooShort(maxReadLength: 76),
                "C": .mostReadsTooShort(medianReadLength: 90, maxReadLength: 151),
            ],
            sampleOrder: ["A", "B", "C"]
        ))
        XCTAssertTrue(warning.isSevere)
        XCTAssertEqual(
            warning.message,
            "1 of 3 samples has no reads of 100 bases or longer (A). EsViritu ignores alignments shorter than 100 bases, so it will likely report no viruses for that sample. "
                + "1 of 3 samples has a median read length under 100 bases (C). Reads shorter than 100 bases cannot count toward a detection."
        )
    }

    func testBatchTruncatesLongSampleLists() throws {
        let ids = ["A", "B", "C", "D", "E"]
        let advisories = Dictionary(uniqueKeysWithValues: ids.map { ($0, EsVirituReadLengthAdvisory.allReadsTooShort(maxReadLength: 76)) })
        let warning = try XCTUnwrap(EsVirituReadLengthWarning.make(advisories: advisories, sampleOrder: ids))
        XCTAssertTrue(warning.message.hasPrefix("5 of 5 samples have no reads of 100 bases or longer (A, B, C, and 2 more)."))
        XCTAssertTrue(warning.message.contains("for those samples."))
    }
}
