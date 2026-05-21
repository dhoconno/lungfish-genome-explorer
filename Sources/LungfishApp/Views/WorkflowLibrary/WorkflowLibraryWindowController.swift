import AppKit
import SwiftUI
import LungfishCore
import os.log

private let workflowLibraryLogger = Logger(subsystem: LogSubsystem.app, category: "WorkflowLibrary")

@MainActor
public final class WorkflowLibraryWindowController: NSWindowController, NSToolbarDelegate {
    private static var shared: WorkflowLibraryWindowController?

    private let viewModel = WorkflowLibraryViewModel()

    private enum ToolbarID {
        static let segmentedControl = NSToolbarItem.Identifier("workflowLibrarySegment")
    }

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

        setupToolbar()
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

    private func setupToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "WorkflowLibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.segmentedControl:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let segmented = NSSegmentedControl(
                labels: ["Library", "Installed", "Runs"],
                trackingMode: .selectOne,
                target: self,
                action: #selector(segmentChanged(_:))
            )
            segmented.segmentStyle = .rounded
            segmented.selectedSegment = viewModel.selectedTab.segmentIndex
            segmented.setWidth(84, forSegment: 0)
            segmented.setWidth(92, forSegment: 1)
            segmented.setWidth(68, forSegment: 2)
            segmented.setAccessibilityIdentifier(WorkflowLibraryAccessibilityID.toolbarSegmentedControl)
            item.view = segmented
            item.label = "Sections"
            item.toolTip = "Switch between Library, Installed, and Runs"
            return item
        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.segmentedControl]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        viewModel.selectedTab = WorkflowLibraryViewModel.Tab.from(segmentIndex: sender.selectedSegment)
    }
}
