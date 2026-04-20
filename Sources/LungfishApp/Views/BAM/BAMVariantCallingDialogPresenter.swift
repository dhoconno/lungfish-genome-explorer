import AppKit
import SwiftUI
import LungfishIO

@MainActor
struct BAMVariantCallingDialogPresenter {
    static func present(
        from window: NSWindow,
        bundle: ReferenceBundle,
        sidebarItems: [DatasetOperationToolSidebarItem] = BAMVariantCallingCatalog.availableSidebarItems(),
        onRun: ((BAMVariantCallingDialogState) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        let state = BAMVariantCallingDialogState(bundle: bundle, sidebarItems: sidebarItems)

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        panel.title = "Call Variants"
        panel.isReleasedWhenClosed = false

        let dialog = BAMVariantCallingDialog(
            state: state,
            onCancel: {
                window.endSheet(panel)
                onCancel?()
            },
            onRun: {
                window.endSheet(panel)
                onRun?(state)
            }
        )

        let hostingController = NSHostingController(rootView: dialog)
        panel.contentViewController = hostingController
        panel.setContentSize(NSSize(width: 980, height: 700))
        window.beginSheet(panel)
    }
}
