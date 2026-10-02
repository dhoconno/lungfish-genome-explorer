// TaxaCollectionsDrawerDelegate.swift - Delegate protocol for the taxa collections drawer
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import os.log

// MARK: - TaxaCollectionsDrawerDelegate

/// Delegate protocol for the taxa collections drawer.
///
/// Provides callbacks for drawer resize gestures. Batch extraction goes
/// through ``TaxaCollectionsDrawerView/onBatchExtract`` alone, so one
/// Extract click starts exactly one extraction.
@MainActor
public protocol TaxaCollectionsDrawerDelegate: AnyObject {
    /// Called when the user drags the divider to resize the drawer.
    ///
    /// - Parameters:
    ///   - drawer: The drawer being resized.
    ///   - deltaY: Vertical delta in points (positive = taller).
    func taxaCollectionsDrawerDidDragDivider(_ drawer: TaxaCollectionsDrawerView, deltaY: CGFloat)

    /// Called when the user finishes dragging the divider.
    ///
    /// - Parameter drawer: The drawer that was resized.
    func taxaCollectionsDrawerDidFinishDraggingDivider(_ drawer: TaxaCollectionsDrawerView)
}
