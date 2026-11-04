// BlastConsentSheet.swift - The line a person reads before a BLAST route with no popover sends anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// What the NVD, Assembly, 12S and FASTA selection routes ask before their sequences leave this Mac. Each of them
/// starts on one click and has no `BlastConfigPopoverView` to carry the line (UX-BLAST-WORDS Q4).
@MainActor
enum BlastConsentSheet {
    /// What a test puts in place of the sheet. It gets the line, and calling `send` is the person's Run BLAST.
    static var presenterForTesting: ((_ line: String, _ send: @escaping @MainActor () -> Void) -> Void)?
}
