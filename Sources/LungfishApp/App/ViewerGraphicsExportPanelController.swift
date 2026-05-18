// ViewerGraphicsExportPanelController.swift - viewer graphics save panel accessory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class ViewerGraphicsExportPanelController: NSObject {
    let panel: NSSavePanel
    let formats: [ViewerGraphicFormat]
    let scopes: [ViewerExportScope]

    private let scopePopup: NSPopUpButton
    private let formatPopup: NSPopUpButton
    private let scalePopup: NSPopUpButton

    init(
        formats requestedFormats: [ViewerGraphicFormat],
        scopes requestedScopes: [ViewerExportScope],
        initialFormat requestedInitialFormat: ViewerGraphicFormat
    ) {
        let resolvedFormats = requestedFormats.isEmpty ? [.png] : requestedFormats
        let resolvedScopes = requestedScopes.isEmpty ? [.tracks] : requestedScopes
        let resolvedInitialFormat = resolvedFormats.contains(requestedInitialFormat)
            ? requestedInitialFormat
            : resolvedFormats[0]

        self.formats = resolvedFormats
        self.scopes = resolvedScopes
        self.panel = AppFilePanelFactory.viewerGraphicsExportPanel(
            formats: resolvedFormats,
            initialFormat: resolvedInitialFormat
        )
        self.scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        self.formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        self.scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)

        super.init()

        configureAccessory(initialFormat: resolvedInitialFormat)
    }

    var selectedScope: ViewerExportScope {
        scopes[clampedIndex(scopePopup.indexOfSelectedItem, upperBound: scopes.count)]
    }

    var selectedFormat: ViewerGraphicFormat {
        formats[clampedIndex(formatPopup.indexOfSelectedItem, upperBound: formats.count)]
    }

    var selectedBitmapScale: CGFloat {
        switch scalePopup.indexOfSelectedItem {
        case 2: return 4
        case 1: return 2
        default: return 1
        }
    }

    var testingIsScaleSelectionEnabled: Bool {
        scalePopup.isEnabled
    }

    func normalizedOutputURL(from rawURL: URL) -> URL {
        let format = selectedFormat
        return rawURL.pathExtension.lowercased() == format.fileExtension
            ? rawURL
            : rawURL.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    private func configureAccessory(initialFormat: ViewerGraphicFormat) {
        scopePopup.addItems(withTitles: scopes.map(\.title))
        if let index = scopes.firstIndex(of: .tracks) {
            scopePopup.selectItem(at: index)
        }

        formatPopup.addItems(withTitles: formats.map(\.title))
        if let index = formats.firstIndex(of: initialFormat) {
            formatPopup.selectItem(at: index)
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))

        ["1x", "2x", "4x"].forEach { scalePopup.addItem(withTitle: $0) }
        scalePopup.selectItem(at: 1)

        let accessory = NSStackView(views: [
            NSTextField(labelWithString: "Scope:"),
            scopePopup,
            NSTextField(labelWithString: "Format:"),
            formatPopup,
            NSTextField(labelWithString: "Bitmap Scale:"),
            scalePopup,
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        panel.accessoryView = accessory

        updateFormatDependentState()
    }

    @objc private func formatChanged(_ sender: Any?) {
        updateFormatDependentState()
    }

    private func updateFormatDependentState() {
        let format = selectedFormat
        scalePopup.isEnabled = !format.isVector

        let currentName = panel.nameFieldStringValue
        let baseName = currentName.isEmpty
            ? "viewer-export"
            : (currentName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
    }

    private func clampedIndex(_ index: Int, upperBound: Int) -> Int {
        max(0, min(max(upperBound - 1, 0), index))
    }
}
