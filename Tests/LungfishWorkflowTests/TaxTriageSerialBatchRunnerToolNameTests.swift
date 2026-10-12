// TaxTriageSerialBatchRunnerToolNameTests.swift - The serial runner names its sample steps by the shared fact
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane B13, row 257 of the Phase 2.8 plan. The serial batch runner records one TaxTriage step for each sample,
// completed or failed, and named the tool with a literal. It names the tool with `TaxTriageRecordFacts.toolName` now,
// the one name of a TaxTriage step (RT4), with the record unchanged. `TaxTriageRecordFreezeTests` pins the record's
// bytes, the names of its steps among them. This pin keeps the runner on the fact, so a new name for the tool moves
// every record at once.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageSerialBatchRunnerToolNameTests: XCTestCase {

    private func runnerSource() throws -> String {
        try String(
            contentsOf: ProvenanceCompatCorpus.repositoryRoot
                .appendingPathComponent("Sources/LungfishWorkflow/TaxTriage/TaxTriageSerialBatchRunner.swift"),
            encoding: .utf8
        )
    }

    /// The fact is the name the batch record has always given each sample, so naming the steps by it moves no byte.
    func testTheFactIsTheNameTheBatchRecordGivesEachSample() {
        XCTAssertEqual(TaxTriageRecordFacts.toolName, "taxtriage")
    }

    /// Both sample steps, the completed one and the failed one, take their tool from the fact, and the runner holds no
    /// literal of the name. The batch's own step keeps its app-level name.
    func testTheSampleStepsTakeTheirToolFromTheFact() throws {
        let source = try runnerSource()

        XCTAssertEqual(source.components(separatedBy: "toolName: TaxTriageRecordFacts.toolName,").count - 1, 2)
        XCTAssertFalse(source.contains("toolName: \"taxtriage\""), "no literal of the tool name")
        XCTAssertTrue(source.contains("toolName: \"lungfish-app-taxtriage-serial-batch\""), "the batch step keeps its name")
    }
}
