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
        // The dialog's tiled default. The dialog marks every option it sends as supplied. The command names the mode,
        // and names no flag for the default bounds (the command's own 90 and 110 percent), for a path that is not set
        // (the BLAST database and the compatible primers) or for the default cumulative consensus threshold, so those
        // stay unnamed. Measured with LUNGFISH_PARITY_DUMP in lane 12.16 c4, and the resolved values are equal.
        try await assertPrimerSchemeParity(
            .varvamp, engine: .varVAMP, tool: "varvamp",
            residue: [
                "common": ["minimumAmpliconLength", "maximumAmpliconLength"],
                "varvamp": ["blastDatabasePath", "compatiblePrimersPath", "cumulativeConsensusThreshold"],
            ]
        )
    }
}
