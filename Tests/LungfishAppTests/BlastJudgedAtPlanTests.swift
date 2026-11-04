// BlastJudgedAtPlanTests.swift - The leaf is told what a BLAST row was judged at
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, BLAST-ESVIRITU-FIRST-WORD (BIO R1 lines 98-115). The viewer runs `blast submit`, so the basis the plan
// used has to cross the process boundary as an option, or the record the leaf writes would carry none. The option is
// sent only when the plan has a basis, so every other route's command is the same as before.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore

final class BlastJudgedAtPlanTests: XCTestCase {
    private func request(judgedAt: String?) -> BlastSubmitRequest {
        BlastSubmitRequest(
            queryURL: URL(fileURLWithPath: "/tmp/query.fasta"), outputURL: URL(fileURLWithPath: "/tmp/out"),
            label: "Taxon", judgedAt: judgedAt
        )
    }

    func testTheLeafIsToldWhatTheRowWasJudgedAt() {
        for basis in BlastTaxonomyContext.Basis.allCases {
            let arguments = CLIBlastSubmitRunner.arguments(for: request(judgedAt: basis.rawValue))
            XCTAssertEqual(arguments.firstIndex(of: "--judged-at").map { arguments[$0 + 1] }, basis.rawValue)
        }
        XCTAssertFalse(
            CLIBlastSubmitRunner.arguments(for: request(judgedAt: nil)).contains("--judged-at"),
            "a plan with no basis sends no option, so an older route's command is unchanged"
        )
    }
}
