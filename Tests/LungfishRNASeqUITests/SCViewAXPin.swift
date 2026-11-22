// SCViewAXPin.swift - The accessibility elements of a view in the order VoiceOver reaches them (5.6 Q1, lane TV-SCVIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// The ordered accessibility elements of a view, for the tests that pin what VoiceOver reaches and in which order.
///
/// AppKit hands VoiceOver the subviews of a view in order. A plain container such as a stack adds nothing of its own, a
/// view that carries an accessibility id is one element that stands for its whole subtree (a grid, a table, a plot or an
/// info button), and a text field without an id is an element named by its words, as a section heading is. A hidden view
/// is not reached. The pin is the list of those names, so a moved sentence shows as one replaced entry.
@MainActor
enum SCViewAXPin {
    static func elements(in view: NSView) -> [String] {
        var found: [String] = []
        collect(view, into: &found)
        return found
    }

    private static func collect(_ view: NSView, into found: inout [String]) {
        for child in view.subviews where !child.isHidden {
            let id = child.accessibilityIdentifier()
            if !id.isEmpty {
                found.append(id)
            } else if let field = child as? NSTextField {
                found.append("text:\(field.stringValue)")
            } else {
                collect(child, into: &found)
            }
        }
    }
}
