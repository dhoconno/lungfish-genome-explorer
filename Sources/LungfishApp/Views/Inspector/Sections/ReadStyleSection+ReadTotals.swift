// ReadStyleSection+ReadTotals.swift - What the Inspector's Total Mapped and Total Unmapped rows count
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ReadStyleSectionViewModel {
    var totalMappedLabel: String { "Total Mapped" }
    var totalUnmappedLabel: String { "Total Unmapped" }
    var alignmentOnlyRows: [(label: String, value: Int64)] { [] }
    var alignmentCountsNote: String? { nil }
}
