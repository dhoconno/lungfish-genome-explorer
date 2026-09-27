// ViewerZoomAvailability.swift - One rule for when View > Zoom items are enabled
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Decides whether the `View > Zoom In / Zoom Out / Zoom to Fit / Zoom Reset`
/// items have anything to act on.
///
/// The items are nil-target, so AppKit validates them against the first
/// responder in the chain that implements the selector. `MainWindowController`
/// sits ahead of `AppDelegate` in that chain and implements the zoom actions,
/// so it must validate them with the same rule `AppDelegate` uses, or the
/// items stay enabled with nothing on screen and silently do nothing.
enum ViewerZoomAvailability {
    /// Zoom needs either an active reference frame or an active MSA viewer
    /// (mirrors the guards in each `ViewerViewController.zoom*()`).
    @MainActor
    static func canZoom(viewerController: ViewerViewController?) -> Bool {
        viewerController?.referenceFrame != nil
            || viewerController?.multipleSequenceAlignmentViewController != nil
    }

    /// The zoom selectors the rule applies to.
    static let zoomSelectors: [Selector] = [
        #selector(ViewMenuActions.zoomIn(_:)),
        #selector(ViewMenuActions.zoomOut(_:)),
        #selector(ViewMenuActions.zoomToFit(_:)),
        #selector(ViewMenuActions.zoomReset(_:)),
    ]
}
