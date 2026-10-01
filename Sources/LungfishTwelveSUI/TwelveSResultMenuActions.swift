// TwelveSResultMenuActions.swift - Menu bar handlers for a 12S amplicon result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Menu bar handlers for the front 12S amplicon result.
///
/// File > Export > 12S Result… sends this to the first responder. The
/// result view controller adopts it and presents the export format list as
/// a sheet, the same choice the result window's export button pops up, so
/// the formats are reachable without a mouse. Disabled while no 12S result
/// is in front.
@MainActor
@objc public protocol TwelveSResultMenuActions {
    func exportTwelveSResult(_ sender: Any?)
}
