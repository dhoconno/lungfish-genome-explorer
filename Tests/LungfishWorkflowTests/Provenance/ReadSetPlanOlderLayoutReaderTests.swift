// ReadSetPlanOlderLayoutReaderTests.swift - A record from before the plan's one home still opens and reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// Lane B33 of Phase 2.10 (ARCH 4), a pin that passes at the base (QA 1). Once the Kraken2 and EsViritu
/// pipelines write the read-set plan under `options.resolvedDefaults` themselves, a record that an earlier
/// build wrote still holds it under `options.explicit`. Such a record opens and reads through the one
/// reader (`ProvenanceEnvelope.readSetPlan`), which looks in the resolved defaults first and in the
/// explicit options next. The two recorder captures of `Tests/Fixtures/provenance-recorder` show it. One
/// holds the plan among the explicit options, where the recorder merged a run parameter. The other holds
/// no plan at all, and the reader says so instead of failing. A capture masks each run and step id as
/// `<id-N>`, so the test gives each a stable UUID before it decodes the bytes.
final class ReadSetPlanOlderLayoutReaderTests: XCTestCase {
    private static let recorderFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/provenance-recorder", isDirectory: true)

    func testARecordWithThePlanAmongTheExplicitOptionsOpensAndReadsThroughTheOneReader() throws {
        let record = try load("read-set-plan-parameter")

        XCTAssertNotNil(record.options.explicit[RecordedReadSetPlan.key], "the older layout files the plan under explicit")
        XCTAssertNil(record.options.resolvedDefaults[RecordedReadSetPlan.key])
        let plan = try XCTUnwrap(record.readSetPlan, "the one reader finds it")
        XCTAssertEqual(plan.place, .explicitOptions)
        XCTAssertEqual(plan.fields["capability"], .string("pairsOrSinglesPerRun"))
        XCTAssertEqual(plan.fields["runs"], .integer(2))
        XCTAssertEqual(plan.fields["singleReadReason"], .string("orphan reads run as single reads"))
        XCTAssertEqual(record.options.explicit["database"], .string("Viral"), "the rest of the record reads as it did")
    }

    func testARecordWithNoPlanOpensAndReadsNone() throws {
        let record = try load("cancelled-after-exit-zero")

        XCTAssertEqual(record.status, .cancelled)
        XCTAssertEqual(record.options.explicit["rank"], .string("S"))
        XCTAssertNil(record.readSetPlan, "a record without a plan says nothing about pairing")
    }

    // MARK: - Helpers

    private func load(_ name: String) throws -> ProvenanceEnvelope {
        let bytes = try Data(contentsOf: Self.recorderFolder.appendingPathComponent("\(name).json"))
        var text = String(decoding: bytes, as: UTF8.self)
        for number in 1...12 {
            let id = String(format: "00000000-0000-4000-8000-%012d", number)
            text = text.replacingOccurrences(of: "<id-\(number)>", with: id)
        }
        return try ProvenanceEnvelopeReader.decode(Data(text.utf8))
    }
}
