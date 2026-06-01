// PasteboardWriting.swift — Test seam for writing strings to NSPasteboard
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Test seam for writing strings to `NSPasteboard`.
@MainActor
public protocol PasteboardWriting {
    func setString(_ string: String)
}
