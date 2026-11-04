// OperationCenter+QuitList.swift - What a quit of LGE would end
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension OperationCenter {
    /// The operations a quit would end, which the quit alert lists. A BLAST search stays out, since a quit leaves it at
    /// NCBI and LGE checks it again at the next launch (UX-BLAST-WORDS Q3).
    public var quitListItems: [Item] {
        activeItems.filter { $0.operationType != .blastVerification }
    }

    /// Whether a BLAST search is under way or waiting, so that a quit alert for other work says it stays at NCBI.
    public var hasBlastSearchThatStays: Bool {
        items.contains { $0.operationType == .blastVerification && ($0.state.isActive || $0.state == .waiting) }
    }
}
