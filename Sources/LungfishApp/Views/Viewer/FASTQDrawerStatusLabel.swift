// FASTQDrawerStatusLabel.swift - The metadata drawer's status line: it wraps, and its tooltip is its whole message
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Review DEMUXPLAN-UX, should-fix 2. A refusal of Demultiplex… runs to 170 characters and ends with the next step, so
// the line wraps to three lines. Whatever still does not fit stays readable as the tooltip, which follows every message
// the drawer writes, so it never holds an earlier one.

import AppKit

final class FASTQDrawerStatusLabel: NSTextField {
    override var stringValue: String {
        didSet { toolTip = stringValue }
    }
}
