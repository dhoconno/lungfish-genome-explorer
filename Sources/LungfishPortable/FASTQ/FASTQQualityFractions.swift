// FASTQQualityFractions.swift - Base counts at or above Q20 and Q30
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Base counts at or above Q20 and Q30, and the percentages they give.
public struct FASTQQualityFractions: Sendable, Equatable {
    public let baseCount: Int64
    public let q20Count: Int64
    public let q30Count: Int64

    public init(baseCount: Int64, q20Count: Int64, q30Count: Int64) {
        self.baseCount = baseCount
        self.q20Count = q20Count
        self.q30Count = q30Count
    }

    public var q20Percentage: Double {
        baseCount > 0 ? Double(q20Count) / Double(baseCount) * 100 : 0
    }

    public var q30Percentage: Double {
        baseCount > 0 ? Double(q30Count) / Double(baseCount) * 100 : 0
    }
}
