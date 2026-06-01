// PhylogeneticTreeSelectionState.swift - Inspector selection payload for tree nodes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct PhylogeneticTreeSelectionState: Equatable {
    public let title: String
    public let subtitle: String?
    public let detailRows: [(String, String)]

    public init(title: String, subtitle: String?, detailRows: [(String, String)]) {
        self.title = title
        self.subtitle = subtitle
        self.detailRows = detailRows
    }

    public static func == (
        lhs: PhylogeneticTreeSelectionState,
        rhs: PhylogeneticTreeSelectionState
    ) -> Bool {
        lhs.title == rhs.title &&
            lhs.subtitle == rhs.subtitle &&
            lhs.detailRows.elementsEqual(rhs.detailRows, by: { $0.0 == $1.0 && $0.1 == $1.1 })
    }
}
