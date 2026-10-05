// AnnotationTableDrawerView+EmbeddedKeyViews.swift - The drawer's keyboard route when a host pane embeds it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

extension AnnotationTableDrawerView {
    /// The drawer's key views for a host pane, such as the MSA bottom pane:
    /// the annotation filter field, the visible search bar and header bar
    /// controls in reading order, then the table (re-review S4). Hidden
    /// controls and plain labels stay off the route. The host relinks on
    /// each tab switch, so the route follows what the drawer shows.
    var embeddedKeyViewChain: [NSView] {
        let controls = [searchBar, headerBar].flatMap { bar in
            bar.subviews
                .filter(isEmbeddedKeyViewCandidate)
                .enumerated()
                .sorted { lhs, rhs in
                    let left = lhs.element.frame.minX
                    let right = rhs.element.frame.minX
                    return left == right ? lhs.offset < rhs.offset : left < right
                }
                .map(\.element)
        }
        return [annotationFilterField] + controls + [tableView]
    }

    /// Links the embedded chain in order and returns its first and last views.
    @discardableResult
    func linkEmbeddedKeyViewChain() -> (first: NSView, last: NSView) {
        let chain = embeddedKeyViewChain
        for (view, next) in zip(chain, chain.dropFirst()) { view.nextKeyView = next }
        return (chain[0], chain[chain.count - 1])
    }

    private func isEmbeddedKeyViewCandidate(_ view: NSView) -> Bool {
        guard view !== annotationFilterField, view !== dragHandle, !view.isHidden, view is NSControl else { return false }
        // A disabled control stays on the route, since AppKit skips it until it is enabled.
        if let field = view as? NSTextField, !field.isEditable { return false }
        return true
    }
}
