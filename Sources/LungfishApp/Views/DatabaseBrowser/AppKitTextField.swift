import AppKit
import SwiftUI
import LungfishCore

@MainActor
struct AppKitTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var accessibilityIdentifier: String?
    var onSubmit: (() -> Void)?

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: NSFont.systemFontSize)
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.sendsActionOnEndEditing = false
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.textFieldAction(_:))
        if let accessibilityIdentifier {
            textField.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.accessibilityIdentifier() != accessibilityIdentifier {
            nsView.setAccessibilityIdentifier(accessibilityIdentifier)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitTextField

        init(_ parent: AppKitTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        @objc func textFieldAction(_ sender: NSTextField) {
            parent.onSubmit?()
        }
    }
}
