import AppKit

extension AppDelegate {
    @objc func showPersistenceInformation(_ sender: Any?) {
        if let existing = persistenceInformationAlert, existing.window.isVisible {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Saving in Lungfish"
        alert.informativeText = "Project changes are stored when an import or edit completes successfully. Check Operations for running or failed work. Editing tools may ask you to apply or discard a draft before you leave.\n\nLungfish remembers project windows and views when they close or the app quits. Use File > Export to create a separate data file; exporting is distinct from saving view state."
        alert.addButton(withTitle: "OK")
        if let window = activeMainWindowController(sender: sender)?.window ?? NSApp?.keyWindow ?? NSApp?.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            retainDetachedPersistenceInformationAlert(alert)
            alert.window.center()
            alert.window.makeKeyAndOrderFront(nil)
        }
    }

    /// A detached NSAlert has no sheet session to retain it or end presentation.
    /// Keep one owned alert and give its only button an explicit nonmodal close.
    func retainDetachedPersistenceInformationAlert(_ alert: NSAlert) {
        persistenceInformationAlert?.window.close()
        persistenceInformationAlert = alert
        alert.window.isReleasedWhenClosed = false
        alert.window.styleMask.remove(.closable)
        alert.buttons.first?.target = self
        alert.buttons.first?.action = #selector(dismissPersistenceInformation(_:))
    }

    @objc func dismissPersistenceInformation(_ sender: Any?) {
        guard let alert = persistenceInformationAlert else { return }
        persistenceInformationAlert = nil
        alert.window.close()
    }
}
