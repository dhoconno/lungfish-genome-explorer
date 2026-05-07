// ClassifierUniqueReads.swift - Shared classifier unique-read display invariants
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum ClassifierUniqueReads {
    static func normalized(stored: Int?, readCount: Int) -> Int? {
        guard let stored else { return nil }
        return normalizedOrFloor(stored: stored, readCount: readCount)
    }

    static func normalizedOrFloor(stored: Int?, readCount: Int) -> Int {
        let floor = readCount > 0 ? 1 : 0
        return max(stored ?? floor, floor)
    }
}
