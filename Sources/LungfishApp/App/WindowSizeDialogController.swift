// WindowSizeDialogController.swift - App window size sheet
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

@MainActor
final class WindowSizeDialogController: NSObject {
    private weak var parentWindow: NSWindow?
    private let onDismiss: () -> Void
    private let panel: NSPanel
    private let widthField: NSTextField
    private let heightField: NSTextField
    private let validationLabel: NSTextField

    init(parentWindow: NSWindow, onDismiss: @escaping () -> Void) {
        self.parentWindow = parentWindow
        self.onDismiss = onDismiss

        let currentSize = parentWindow.contentLayoutRect.size
        widthField = Self.makeNumberField(value: currentSize.width, identifier: "window-size-width-field")
        heightField = Self.makeNumberField(value: currentSize.height, identifier: "window-size-height-field")
        validationLabel = NSTextField(labelWithString: "")
        validationLabel.textColor = .lungfishDanger
        validationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        validationLabel.setAccessibilityIdentifier("window-size-validation-label")

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .docModalWindow],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.title = "Set Window Size"
        panel.isReleasedWhenClosed = false
        panel.contentView = makeContentView()
    }

    func beginSheet() {
        guard let parentWindow else {
            onDismiss()
            return
        }
        parentWindow.beginSheet(panel) { [weak self] _ in
            self?.onDismiss()
        }
        panel.makeFirstResponder(widthField)
    }

    @objc private func cancel(_ sender: Any?) {
        endSheet()
    }

    @objc private func apply(_ sender: Any?) {
        guard let parentWindow else {
            endSheet()
            return
        }

        let request = WindowSizeRequest(widthText: widthField.stringValue, heightText: heightField.stringValue)
        guard let size = request.contentSize else {
            validationLabel.stringValue = "Enter positive width and height values in points."
            NSSound.beep()
            return
        }

        WindowSizeRequest.apply(size, to: parentWindow)
        endSheet()
    }

    private func endSheet() {
        guard let parentWindow else {
            panel.close()
            onDismiss()
            return
        }
        parentWindow.endSheet(panel)
    }

    private func makeContentView() -> NSView {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 210))
        contentView.setAccessibilityIdentifier("window-size-dialog")

        let titleLabel = NSTextField(labelWithString: "Set Window Size")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)

        let infoLabel = NSTextField(wrappingLabelWithString: "Enter the app window content size in points.")
        infoLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width:"), widthField, NSTextField(labelWithString: "pt")],
            [NSTextField(labelWithString: "Height:"), heightField, NSTextField(labelWithString: "pt")]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 104
        grid.rowSpacing = 8
        grid.columnSpacing = 8

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityIdentifier("window-size-cancel-button")

        let setButton = NSButton(title: "Set", target: self, action: #selector(apply(_:)))
        setButton.bezelStyle = .rounded
        setButton.keyEquivalent = "\r"
        setButton.setAccessibilityIdentifier("window-size-set-button")
        panel.defaultButtonCell = setButton.cell as? NSButtonCell

        let buttonStack = NSStackView(views: [cancelButton, setButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 12
        buttonStack.alignment = .centerY

        for view in [titleLabel, infoLabel, grid, validationLabel, buttonStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),

            infoLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            infoLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            infoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            grid.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            validationLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 8),
            validationLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            validationLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            buttonStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        return contentView
    }

    private static func makeNumberField(value: CGFloat, identifier: String) -> NSTextField {
        let field = NSTextField(string: String(Int(value.rounded())))
        field.alignment = .right
        field.controlSize = .regular
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setAccessibilityRole(.textField)
        field.setAccessibilityIdentifier(identifier)
        return field
    }
}
