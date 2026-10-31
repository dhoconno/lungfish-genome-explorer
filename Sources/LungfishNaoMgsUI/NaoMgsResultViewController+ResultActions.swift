// NaoMgsResultViewController+ResultActions.swift - NAO-MGS's shared classifier actions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane ADOPT (plan exit check 4, O86, UX-3E-LABELS).

import AppKit
import LungfishKit

extension NaoMgsResultViewController {

    // MARK: - Testing Accessors

    /// Starts BLAST for displayed row `index` with `readCount` reads, as Run in the BLAST popover does.
    func testingVerifyWithBlast(row index: Int, readCount: Int) {
        guard displayedRows.indices.contains(index) else { return }
        executeBlastVerification(BlastMenuSelection(row: displayedRows[index], readCount: readCount))
    }
}
