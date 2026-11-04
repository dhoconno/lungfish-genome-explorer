// OperationCenter+QuitList.swift - What a quit alert says of a BLAST search
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension OperationCenter {
    /// Whether a BLAST search is under way or waiting beside the operations an alert lists, so that the alert says it
    /// stays at NCBI.
    public func hasBlastSearchThatStays(beside listed: [Item]) -> Bool {
        items.contains { item in
            item.operationType == .blastVerification && (item.state.isActive || item.state == .waiting)
                && !listed.contains { $0.id == item.id }
        }
    }
}
