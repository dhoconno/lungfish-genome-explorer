import AppKit

extension AppDelegate {
    @objc func showPersistenceInformation(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Saving in Lungfish"
        alert.informativeText = "Project changes are stored when an import or edit completes successfully. Check Operations for running or failed work. Editing tools may ask you to apply or discard a draft before you leave.\n\nLungfish remembers project windows and views when they close or the app quits. Use File > Export to create a separate data file; exporting is distinct from saving view state."
        alert.addButton(withTitle: "OK")
        if let window = activeMainWindowController(sender: sender)?.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
