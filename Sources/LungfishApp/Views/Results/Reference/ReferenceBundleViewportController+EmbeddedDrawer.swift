// ReferenceBundleViewportController+EmbeddedDrawer.swift - The drawer a reference viewport offers to the menu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane DRAWER-ROUTE (WF-6). The viewport draws its bundle in an embedded viewer, and that viewer owns the
// annotation drawer a person sees. The host viewer behind the viewport holds no bundle and no index, so View > Show
// Drawer, the window toolbar's drawer button and Make Drawer Taller or Shorter reach the embedded drawer through
// these three members, and the host forwards to them while the viewport is its child
// (`ViewerViewController.drawerOwningReferenceViewport`). The embedded viewer has no viewport child of its own, so
// the forward cannot recurse.

import AppKit

extension ReferenceBundleViewportController {
    /// Shows the embedded viewer's drawer when it is hidden and hides it when it is shown. The embedded viewer makes
    /// the drawer on the first call when its bundle opened none, as a mapping result's reference with no annotation
    /// or variant track does.
    func toggleEmbeddedAnnotationDrawer() {
        activeSequenceViewerController.toggleAnnotationDrawer()
    }

    /// Whether the embedded viewer's drawer is shown. The menu title and the toolbar button read it.
    var isEmbeddedAnnotationDrawerOpen: Bool {
        activeSequenceViewerController.isAnnotationDrawerOpen
    }

    /// Makes the embedded viewer's drawer taller or shorter by one keyboard step, opening it first when it is closed.
    func adjustEmbeddedAnnotationDrawerHeight(by delta: CGFloat) {
        activeSequenceViewerController.adjustAnnotationDrawerHeight(by: delta)
    }
}
