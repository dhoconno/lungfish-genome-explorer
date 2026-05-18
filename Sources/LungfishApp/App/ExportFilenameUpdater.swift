// ExportFilenameUpdater.swift - save-panel filename synchronization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// Helper that updates NSSavePanel filename when format/compression popups change.
@MainActor
final class ExportFilenameUpdater: NSObject {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    weak var panel: NSSavePanel?
    let baseName: String
    let formatPopup: NSPopUpButton
    let compPopup: NSPopUpButton

    init(panel: NSSavePanel, baseName: String, formatPopup: NSPopUpButton, compPopup: NSPopUpButton) {
        self.panel = panel
        self.baseName = baseName
        self.formatPopup = formatPopup
        self.compPopup = compPopup
    }

    @objc func popupChanged(_ sender: Any?) {
        let formatExt = formatPopup.indexOfSelectedItem == 1 ? "gbk" : "fa"
        let compExt: String
        switch compPopup.indexOfSelectedItem {
        case 1: compExt = ".gz"
        case 2: compExt = ".zst"
        default: compExt = ""
        }
        panel?.nameFieldStringValue = "\(baseName).\(formatExt)\(compExt)"
    }
}
