// ClassifierUniqueReads.swift - Shared classifier unique-read display invariants
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ClassifierUniqueReads {
    /// The count a screen shows and an export writes for a row. Nil when the count was never computed, which a screen
    /// shows as a dash and an export writes as an empty cell. A stored count is raised to 1 only when the row has reads.
    public static func normalized(stored: Int?, readCount: Int) -> Int? {
        guard let stored else { return nil }
        return normalizedOrFloor(stored: stored, readCount: readCount)
    }

    /// A stored count raised to 1 only when the row has reads. It takes no nil, so a caller cannot make up a count for a
    /// row whose count was never computed (a false 1 beside thousands of reads reads as nearly all duplicates).
    public static func normalizedOrFloor(stored: Int, readCount: Int) -> Int {
        max(stored, readCount > 0 ? 1 : 0)
    }
}
