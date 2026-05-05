// LungfishAppKitControlStyle.swift - Shared AppKit control metrics
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
enum LungfishAppKitControlStyle {
    static var inspectorControlFont: NSFont {
        .systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    static var inspectorEmphasizedControlFont: NSFont {
        .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    }

    static func applyInspectorMetrics(to control: NSControl, emphasized: Bool = false) {
        control.controlSize = .small
        control.font = emphasized ? inspectorEmphasizedControlFont : inspectorControlFont
    }

    static func applyInspectorMetrics(to segmentedControl: NSSegmentedControl) {
        segmentedControl.controlSize = .small
        segmentedControl.font = inspectorControlFont
        segmentedControl.segmentStyle = .rounded
    }

    static func applyInspectorMetrics(to searchField: NSSearchField) {
        searchField.controlSize = .small
        searchField.font = inspectorControlFont
    }

    static func configureInspectorIconButton(
        _ button: NSButton,
        symbolName: String,
        fallbackTitle: String,
        accessibilityLabel: String
    ) {
        applyInspectorMetrics(to: button)
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        if button.image == nil {
            button.title = fallbackTitle
            button.imagePosition = .noImage
        } else {
            button.imagePosition = .imageOnly
        }
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
}
