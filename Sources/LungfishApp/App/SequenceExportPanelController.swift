// SequenceExportPanelController.swift - sequence export format accessory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class SequenceExportPanelController {
    let panel: NSSavePanel

    private let formatPopup: NSPopUpButton
    private let compressionPopup: NSPopUpButton
    private var filenameUpdater: ExportFilenameUpdater?

    init(
        panel: NSSavePanel,
        defaultFormat: SequenceExportFormat,
        filenameBaseName: String?
    ) {
        self.panel = panel
        self.formatPopup = NSPopUpButton(frame: NSRect(x: 64, y: 28, width: 120, height: 24))
        self.compressionPopup = NSPopUpButton(frame: NSRect(x: 84, y: 0, width: 120, height: 24))

        configureAccessory(defaultFormat: defaultFormat, filenameBaseName: filenameBaseName)
    }

    var selectedFormat: SequenceExportFormat {
        formatPopup.indexOfSelectedItem == 1 ? .genbank : .fasta
    }

    var selectedCompression: SequenceExportCompression {
        switch compressionPopup.indexOfSelectedItem {
        case 1: return .gzip
        case 2: return .zstd
        default: return .none
        }
    }

    private func configureAccessory(
        defaultFormat: SequenceExportFormat,
        filenameBaseName: String?
    ) {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.frame = NSRect(x: 0, y: 32, width: 60, height: 18)
        accessory.addSubview(formatLabel)

        formatPopup.controlSize = .small
        formatPopup.addItems(withTitles: ["FASTA", "GenBank"])
        formatPopup.selectItem(at: defaultFormat == .genbank ? 1 : 0)
        formatPopup.tag = 1
        accessory.addSubview(formatPopup)

        let compressionLabel = NSTextField(labelWithString: "Compression:")
        compressionLabel.font = .systemFont(ofSize: 11)
        compressionLabel.frame = NSRect(x: 0, y: 4, width: 80, height: 18)
        accessory.addSubview(compressionLabel)

        compressionPopup.controlSize = .small
        compressionPopup.addItems(withTitles: ["None", "gzip (.gz)", "zstd (.zst)"])
        compressionPopup.tag = 2
        accessory.addSubview(compressionPopup)

        if let filenameBaseName {
            let updater = ExportFilenameUpdater(
                panel: panel,
                baseName: filenameBaseName,
                formatPopup: formatPopup,
                compPopup: compressionPopup
            )
            formatPopup.target = updater
            formatPopup.action = #selector(ExportFilenameUpdater.popupChanged(_:))
            compressionPopup.target = updater
            compressionPopup.action = #selector(ExportFilenameUpdater.popupChanged(_:))
            filenameUpdater = updater
            updater.popupChanged(formatPopup)
        }

        panel.accessoryView = accessory
    }
}
