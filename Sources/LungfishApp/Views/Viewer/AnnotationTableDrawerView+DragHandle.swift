// AnnotationTableDrawerView+DragHandle.swift - Hide the drawer's own resize handle when a host pane owns one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension AnnotationTableDrawerView {
    /// Whether the drawer shows its own drag handle. A host that embeds the
    /// drawer under its own divider, such as the MSA bottom pane, sets this to
    /// false so there is one handle, not two (ruling U1). A hidden handle
    /// collapses to zero height and leaves the key view loop and the
    /// accessibility tree.
    var showsDragHandle: Bool {
        get { !dragHandle.isHidden }
        set {
            dragHandle.isHidden = !newValue
            for constraint in dragHandle.constraints
            where constraint.firstAttribute == .height && constraint.firstItem === dragHandle {
                constraint.constant = newValue ? AnnotationDrawerSizing.dividerHeight : 0
            }
        }
    }
}
