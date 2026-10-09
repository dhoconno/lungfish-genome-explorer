import AppKit
import Combine
import LungfishCore
import LungfishIO
import LungfishKit
import SwiftUI

@MainActor
struct ManualHaplotypeComboBox: NSViewRepresentable {
    let text: String
    let suggestions: [String]
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let accessibilityHelp: String?
    let isEnabled: Bool
    let font: NSFont
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.isEditable = true
        comboBox.completes = true
        comboBox.usesDataSource = false
        comboBox.delegate = context.coordinator
        configure(comboBox)
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.onChange = onChange
        configure(comboBox)
    }

    private func configure(_ comboBox: NSComboBox) {
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
        let existing = comboBox.objectValues.compactMap { $0 as? String }
        if existing != suggestions {
            comboBox.removeAllItems()
            comboBox.addItems(withObjectValues: suggestions)
        }
        comboBox.isEnabled = isEnabled
        comboBox.font = font
        comboBox.setAccessibilityLabel(accessibilityLabel)
        comboBox.setAccessibilityIdentifier(accessibilityIdentifier)
        comboBox.setAccessibilityHelp(accessibilityHelp)
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var onChange: (String) -> Void

        init(onChange: @escaping (String) -> Void) {
            self.onChange = onChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }
            onChange(comboBox.stringValue)
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }
            onChange(comboBox.stringValue)
        }
    }
}
