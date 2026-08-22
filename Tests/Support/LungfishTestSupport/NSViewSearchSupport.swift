// NSViewSearchSupport.swift - shared NSView-tree search helpers for AppKit tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Promoted from three separate `private extension NSView` copies duplicated
// across Tests/LungfishAppTests/WindowAppearanceTests.swift,
// Tests/LungfishAppViewTests/GUIRegressionTests.swift, and
// Tests/LungfishAppViewTests/WorkflowBuilderAppIntegrationTests.swift (fix
// wave for the source-text conversion campaign, 2026-08-22). These are plain
// AppKit tree-walking helpers with no ViewInspector dependency, so they live
// here rather than in a ViewInspector-only test-target support file.

import AppKit

public extension NSView {
    /// Returns the first descendant of the given type in a depth-first traversal,
    /// or `self` if it already matches.
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let match = self as? T {
            return match
        }
        for subview in subviews {
            if let match = subview.firstSubview(of: type) {
                return match
            }
        }
        return nil
    }

    /// Returns the first descendant (or `self`) whose `accessibilityIdentifier()`
    /// equals `identifier`.
    func firstSubview(withAccessibilityIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }

    /// Returns the first descendant `NSButton` whose `title` equals `title`.
    func firstButtonMatching(title: String) -> NSButton? {
        if let button = self as? NSButton, button.title == title {
            return button
        }
        for subview in subviews {
            if let match = subview.firstButtonMatching(title: title) {
                return match
            }
        }
        return nil
    }

    /// True if any descendant `NSTextField`'s `stringValue` contains `text`.
    func containsLabelText(_ text: String) -> Bool {
        if let textField = self as? NSTextField, textField.stringValue.contains(text) {
            return true
        }
        return subviews.contains { $0.containsLabelText(text) }
    }

    /// True if any descendant `NSTextField`/`NSTextView`/`NSButton` contains
    /// `text` in its string/title. Broader than `containsLabelText(_:)`, which
    /// only checks `NSTextField`.
    func containsText(_ text: String) -> Bool {
        if let textField = self as? NSTextField, textField.stringValue.contains(text) {
            return true
        }
        if let textView = self as? NSTextView, textView.string.contains(text) {
            return true
        }
        if let button = self as? NSButton, button.title.contains(text) {
            return true
        }
        return subviews.contains { $0.containsText(text) }
    }

    /// Returns the first descendant `NSControl` (or `self`) whose `toolTip`
    /// equals `toolTip`. `NSControl.applyLungfishHelp(_:)` (LungfishHelpContent.swift)
    /// sets `toolTip = item.summary`, so this proves a specific help item is
    /// actually applied to a real rendered control -- not just that the control
    /// exists -- without needing that control's (often `private`) property name.
    /// Traverses hidden subviews too (a control set up but not yet visible still
    /// carries its real toolTip).
    func firstControl(withToolTip toolTip: String) -> NSControl? {
        if let control = self as? NSControl, control.toolTip == toolTip {
            return control
        }
        for subview in subviews {
            if let match = subview.firstControl(withToolTip: toolTip) {
                return match
            }
        }
        return nil
    }
}
