// PrimerDesignCLIGUIParityReplayTests+VarVAMP.swift - The varVAMP design in the app against the command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.16 M2 (1), PLAN row 12.16 (A67-ENGINES), item 2 of row A67-next of the A67 review, C4 of 2.10 and
// 2.9 O5. The case runs the class's three sides on the PrimalScheme3 case's alignment and the real `varvamp` of the
// managed environment, with the side A and the pins of PrimerDesignCLIGUIParityReplayTests+SchemeEngines.
// A against C and C against C' declare nothing (C4), under OutputEquivalence.MaskPolicy.primerAnalysis.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishKitTestSupport

extension PrimerDesignCLIGUIParityReplayTests {
    func testTheVarVAMPRowWritesWhatTheInProcessRunWroteOnRealVarVAMP() async throws {
        // The dialog's tiled default. The in-process dialog marked every option it sent as supplied, and the command
        // marks only the flags it names, so lane 12.16 c4 measured a residue of five names (the two default bounds, the
        // BLAST database, the compatible primers and the cumulative consensus threshold). Since lane 12.17 M2 side A
        // runs the command, so the app's record marks what the command marks and the residue is empty. The resolved
        // values stay equal.
        try await assertPrimerSchemeParity(
            .varvamp, engine: .varVAMP, tool: "varvamp", residue: ["common": [], "varvamp": []]
        )
    }
}
