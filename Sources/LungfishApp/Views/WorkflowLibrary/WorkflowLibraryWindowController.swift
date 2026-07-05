import AppKit
import SwiftUI
import LungfishCore
import os.log

private let workflowLibraryLogger = Logger(subsystem: LogSubsystem.app, category: "WorkflowLibrary")

@MainActor
public final class WorkflowLibraryWindowController: NSWindowController {
    private static var shared: WorkflowLibraryWindowController?

    private let viewModel = WorkflowLibraryViewModel()

    public static func show() {
        if shared == nil {
            shared = WorkflowLibraryWindowController()
        }
        shared?.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workflow Library"
        window.minSize = NSSize(width: 620, height: 380)
        window.setFrameAutosaveName("WorkflowLibraryWindow")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier(WorkflowLibraryAccessibilityID.window)

        super.init(window: window)

        window.contentView = NSHostingView(rootView: WorkflowLibraryPanelView(viewModel: viewModel))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func showWindow(_ sender: Any?) {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        workflowLibraryLogger.info("Workflow Library window shown")
    }
}
