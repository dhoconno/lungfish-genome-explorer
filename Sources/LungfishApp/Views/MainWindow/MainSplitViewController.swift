// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// The main split view controller managing sidebar, viewer, and inspector panels.
///
/// Layout:
/// ```
/// ┌────────────┬────────────────────────────┬──────────┐
/// │  Sidebar   │         Viewer             │ Inspector│
/// │  (toggle)  │    (always visible)        │ (toggle) │
/// └────────────┴────────────────────────────┴──────────┘
/// ```
@MainActor
public class MainSplitViewController: NSSplitViewController {

    // MARK: - Child View Controllers

    /// The sidebar panel (project/file navigation)
    public private(set) var sidebarController: SidebarViewController!

    /// The main viewer panel (sequence/tracks)
    public private(set) var viewerController: ViewerViewController!

    /// The inspector panel (selection details)
    public private(set) var inspectorController: InspectorViewController!

    // MARK: - Split View Items

    private var sidebarItem: NSSplitViewItem!
    private var viewerItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!

    // MARK: - Configuration

    /// Minimum sidebar width
    private let sidebarMinWidth: CGFloat = 180
    /// Default sidebar width
    private let sidebarDefaultWidth: CGFloat = 220
    /// Maximum sidebar width
    private let sidebarMaxWidth: CGFloat = 350

    /// Minimum inspector width
    private let inspectorMinWidth: CGFloat = 200
    /// Default inspector width
    private let inspectorDefaultWidth: CGFloat = 280
    /// Maximum inspector width
    private let inspectorMaxWidth: CGFloat = 450

    /// Minimum viewer width
    private let viewerMinWidth: CGFloat = 400

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureSplitView()
        configureChildControllers()
        configureKeyboardShortcuts()
        restorePanelState()
    }

    // MARK: - Configuration

    private func configureSplitView() {
        // Use thin dividers for modern look
        splitView.dividerStyle = .thin

        // Vertical splits (side by side)
        splitView.isVertical = true

        // Autosave configuration
        splitView.autosaveName = "MainSplitView"
    }

    private func configureChildControllers() {
        // Create child view controllers
        sidebarController = SidebarViewController()
        viewerController = ViewerViewController()
        inspectorController = InspectorViewController()

        // Create split view items with appropriate behaviors

        // Sidebar: collapsible, sidebar behavior for vibrancy
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth
        sidebarItem.preferredThicknessFraction = 0.15
        sidebarItem.holdingPriority = .defaultLow + 1
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings

        // Viewer: always visible, takes remaining space
        viewerItem = NSSplitViewItem(viewController: viewerController)
        viewerItem.canCollapse = false
        viewerItem.minimumThickness = viewerMinWidth
        viewerItem.holdingPriority = .defaultLow

        // Inspector: collapsible, inspector behavior
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = inspectorMinWidth
        inspectorItem.maximumThickness = inspectorMaxWidth
        inspectorItem.preferredThicknessFraction = 0.2
        inspectorItem.holdingPriority = .defaultLow + 1
        inspectorItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings

        // Add items in order: sidebar, viewer, inspector
        addSplitViewItem(sidebarItem)
        addSplitViewItem(viewerItem)
        addSplitViewItem(inspectorItem)

        // Inspector starts collapsed by default
        inspectorItem.isCollapsed = true
    }

    private func configureKeyboardShortcuts() {
        // Keyboard shortcuts are handled by menu items with key equivalents
        // See MainMenu.swift for menu configuration
    }

    // MARK: - Panel State

    private func savePanelState() {
        let defaults = UserDefaults.standard
        defaults.set(sidebarItem.isCollapsed, forKey: "SidebarCollapsed")
        defaults.set(inspectorItem.isCollapsed, forKey: "InspectorCollapsed")
    }

    private func restorePanelState() {
        let defaults = UserDefaults.standard

        // Restore sidebar state (default: visible)
        if defaults.object(forKey: "SidebarCollapsed") != nil {
            sidebarItem.isCollapsed = defaults.bool(forKey: "SidebarCollapsed")
        }

        // Restore inspector state (default: collapsed)
        if defaults.object(forKey: "InspectorCollapsed") != nil {
            inspectorItem.isCollapsed = defaults.bool(forKey: "InspectorCollapsed")
        }
    }

    // MARK: - Public API

    /// Toggles the sidebar visibility with animation.
    public func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            sidebarItem.animator().isCollapsed.toggle()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.savePanelState()
            }
        }
    }

    /// Toggles the inspector visibility with animation.
    public func toggleInspector() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            inspectorItem.animator().isCollapsed.toggle()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.savePanelState()
            }
        }
    }

    /// Shows or hides the sidebar.
    public func setSidebarVisible(_ visible: Bool, animated: Bool = true) {
        guard sidebarItem.isCollapsed == visible else { return }

        if animated {
            toggleSidebar()
        } else {
            sidebarItem.isCollapsed = !visible
            savePanelState()
        }
    }

    /// Shows or hides the inspector.
    public func setInspectorVisible(_ visible: Bool, animated: Bool = true) {
        guard inspectorItem.isCollapsed == visible else { return }

        if animated {
            toggleInspector()
        } else {
            inspectorItem.isCollapsed = !visible
            savePanelState()
        }
    }

    /// Whether the sidebar is currently visible.
    public var isSidebarVisible: Bool {
        !sidebarItem.isCollapsed
    }

    /// Whether the inspector is currently visible.
    public var isInspectorVisible: Bool {
        !inspectorItem.isCollapsed
    }

    // MARK: - NSSplitViewDelegate

    public override func splitView(
        _ splitView: NSSplitView,
        canCollapseSubview subview: NSView
    ) -> Bool {
        // Allow collapsing sidebar and inspector
        if subview == sidebarController.view {
            return true
        }
        if subview == inspectorController.view {
            return true
        }
        return false
    }

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        // Could update toolbar tracking separators here if needed
    }
}

// MARK: - Accessibility

extension MainSplitViewController {

    public func getAccessibilityLabel() -> String {
        "Main content area"
    }

    public func getAccessibilityChildren() -> [NSView] {
        [sidebarController.view, viewerController.view, inspectorController.view]
    }
}
