// WorkflowBuilderViewController.swift - Main view controller for workflow builder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import UniformTypeIdentifiers
import os.log
import LungfishCore

/// Logger for workflow builder operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "WorkflowBuilderViewController")

// MARK: - WorkflowBuilderViewController

/// Main view controller for the visual workflow builder.
///
/// Provides:
/// - Split view with node palette and canvas
/// - Toolbar with zoom controls, grid toggle, export
/// - File menu integration (New, Open, Save)
/// - Edit menu integration (Undo, Redo, Delete)
/// - Export to Nextflow and Snakemake
@MainActor
public class WorkflowBuilderViewController: NSSplitViewController, NSMenuItemValidation {

    // MARK: - Child View Controllers

    /// The node palette sidebar.
    private var paletteViewController: WorkflowNodePaletteViewController!

    /// The main canvas.
    private var canvasViewController: WorkflowCanvasViewController!

    // MARK: - Split View Items

    private var paletteItem: NSSplitViewItem!
    private var canvasItem: NSSplitViewItem!

    // MARK: - State

    /// The current workflow graph.
    public var graph: WorkflowGraph {
        get { canvasViewController.canvasView.graph }
        set { canvasViewController.canvasView.graph = newValue }
    }

    /// The URL of the current workflow file, if saved.
    public private(set) var workflowURL: URL?

    /// Whether the workflow has unsaved changes.
    public private(set) var hasUnsavedChanges: Bool = false

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        configureSplitView()
        configureChildControllers()
        configureToolbar()
        setupNotifications()

        logger.info("WorkflowBuilderViewController loaded")
    }

    public override func viewWillAppear() {
        super.viewWillAppear()

        // Configure window
        view.window?.title = "Workflow Builder"
        view.window?.subtitle = graph.name
    }

    // MARK: - Configuration

    private func configureSplitView() {
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.autosaveName = "WorkflowBuilderSplitView"
    }

    private func configureChildControllers() {
        // Create palette view controller
        paletteViewController = WorkflowNodePaletteViewController()

        // Create canvas view controller
        canvasViewController = WorkflowCanvasViewController()
        canvasViewController.canvasView.delegate = self

        // Create split view items
        paletteItem = NSSplitViewItem(sidebarWithViewController: paletteViewController)
        paletteItem.canCollapse = true
        paletteItem.minimumThickness = 200
        paletteItem.maximumThickness = 300
        paletteItem.preferredThicknessFraction = 0.2

        canvasItem = NSSplitViewItem(viewController: canvasViewController)
        canvasItem.canCollapse = false
        canvasItem.minimumThickness = 400

        addSplitViewItem(paletteItem)
        addSplitViewItem(canvasItem)
    }

    private func configureToolbar() {
        // Toolbar is configured when the window is ready
        // See windowDidBecomeMain notification
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard notification.object as? NSWindow === view.window else { return }

        // Set up toolbar
        let toolbar = NSToolbar(identifier: "WorkflowBuilderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        view.window?.toolbar = toolbar
        view.window?.toolbarStyle = .unified
    }

    // MARK: - File Operations

    /// Creates a new empty workflow.
    public func newWorkflow() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.hasUnsavedChanges {
                guard let window = self.view.window ?? NSApp.keyWindow else { return }
                let alert = NSAlert()
                alert.messageText = "Save changes to current workflow?"
                alert.informativeText = "Your changes will be lost if you don\'t save them."
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Don\'t Save")
                alert.addButton(withTitle: "Cancel")

                let response = await alert.beginSheetModal(for: window)
                switch response {
                case .alertFirstButtonReturn:
                    self.saveWorkflow()
                case .alertSecondButtonReturn:
                    break
                default:
                    return
                }
            }

            self.graph = WorkflowGraph(name: "New Workflow")
            self.workflowURL = nil
            self.hasUnsavedChanges = false
            self.updateWindowTitle()

            logger.info("Created new workflow")
        }
    }

    /// Opens a workflow from a file.
    public func openWorkflow() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a workflow file"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadWorkflow(from: url)
        }
    }

    /// Loads a workflow from the specified URL.
    public func loadWorkflow(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let loadedGraph = try decoder.decode(WorkflowGraph.self, from: data)

            graph = loadedGraph
            workflowURL = url
            hasUnsavedChanges = false
            updateWindowTitle()

            logger.info("Loaded workflow from: \(url.path)")
        } catch {
            logger.error("Failed to load workflow: \(error.localizedDescription)")

            let alert = NSAlert()
            alert.messageText = "Failed to Open Workflow"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
        }
    }

    /// Saves the current workflow.
    public func saveWorkflow() {
        if let url = workflowURL {
            saveWorkflow(to: url)
        } else {
            saveWorkflowAs()
        }
    }

    /// Saves the current workflow with a new name.
    public func saveWorkflowAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(graph.name).json"
        panel.message = "Save workflow as"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveWorkflow(to: url)
        }
    }

    private func saveWorkflow(to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(graph)
            try data.write(to: url)

            workflowURL = url
            hasUnsavedChanges = false
            updateWindowTitle()

            logger.info("Saved workflow to: \(url.path)")
        } catch {
            logger.error("Failed to save workflow: \(error.localizedDescription)")

            let alert = NSAlert()
            alert.messageText = "Failed to Save Workflow"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = view.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
        }
    }

    // MARK: - Export Operations

    /// Exports the workflow to Nextflow DSL2.
    public func exportToNextflow() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nf") ?? .plainText]
        panel.nameFieldStringValue = "\(graph.name).nf"
        panel.message = "Export as Nextflow pipeline"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }

            do {
                let exporter = NextflowExporter()
                let script = try exporter.export(graph: self.graph)
                try script.write(to: url, atomically: true, encoding: .utf8)

                logger.info("Exported Nextflow pipeline to: \(url.path)")

                // Show success message
                let alert = NSAlert()
                alert.messageText = "Export Successful"
                alert.informativeText = "Nextflow pipeline saved to \(url.lastPathComponent)"
                alert.alertStyle = .informational
                if let window = self.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
            } catch {
                logger.error("Failed to export Nextflow: \(error.localizedDescription)")

                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = self.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// Exports the workflow to Snakemake.
    public func exportToSnakemake() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Snakefile"
        panel.message = "Export as Snakemake workflow"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }

            do {
                let exporter = SnakemakeExporter()
                let snakefile = try exporter.export(graph: self.graph)
                try snakefile.write(to: url, atomically: true, encoding: .utf8)

                logger.info("Exported Snakemake workflow to: \(url.path)")

                // Show success message
                let alert = NSAlert()
                alert.messageText = "Export Successful"
                alert.informativeText = "Snakemake workflow saved to \(url.lastPathComponent)"
                alert.alertStyle = .informational
                if let window = self.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
            } catch {
                logger.error("Failed to export Snakemake: \(error.localizedDescription)")

                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                if let window = self.view.window ?? NSApp.keyWindow {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    // MARK: - View Operations

    /// Toggles the node palette visibility.
    public func togglePalette() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            paletteItem.animator().isCollapsed.toggle()
        }
    }

    /// Toggles grid visibility.
    public func toggleGrid() {
        canvasViewController.canvasView.showGrid.toggle()
    }

    /// Toggles snap to grid.
    public func toggleSnapToGrid() {
        canvasViewController.canvasView.snapToGrid.toggle()
    }

    // MARK: - Helpers

    private func updateWindowTitle() {
        view.window?.subtitle = graph.name
        if hasUnsavedChanges {
            view.window?.isDocumentEdited = true
        } else {
            view.window?.isDocumentEdited = false
        }
    }
}

// MARK: - WorkflowCanvasViewDelegate

extension WorkflowBuilderViewController: WorkflowCanvasViewDelegate {

    public func canvasView(_ canvasView: WorkflowCanvasView, didSelectNode node: WorkflowNode?) {
        // Could update an inspector panel here
        logger.debug("Selected node: \(node?.label ?? "none")")
    }

    public func canvasView(_ canvasView: WorkflowCanvasView, didSelectConnection connection: WorkflowConnection?) {
        logger.debug("Selected connection: \(connection?.id.uuidString ?? "none")")
    }

    public func canvasViewDidModifyGraph(_ canvasView: WorkflowCanvasView) {
        hasUnsavedChanges = true
        updateWindowTitle()
    }
}

// MARK: - NSToolbarDelegate

extension WorkflowBuilderViewController: NSToolbarDelegate {

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .flexibleSpace,
            .workflowZoomIn,
            .workflowZoomOut,
            .workflowZoomReset,
            .space,
            .workflowGridToggle,
            .workflowSnapToggle,
            .flexibleSpace,
            .workflowExport
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .flexibleSpace,
            .space,
            .workflowZoomIn,
            .workflowZoomOut,
            .workflowZoomReset,
            .workflowGridToggle,
            .workflowSnapToggle,
            .workflowExport
        ]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .workflowZoomIn:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom In"
            item.paletteLabel = "Zoom In"
            item.toolTip = "Zoom in (Cmd +)"
            item.image = NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom In")
            item.target = self
            item.action = #selector(zoomIn(_:))
            return item

        case .workflowZoomOut:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Zoom Out"
            item.paletteLabel = "Zoom Out"
            item.toolTip = "Zoom out (Cmd -)"
            item.image = NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom Out")
            item.target = self
            item.action = #selector(zoomOut(_:))
            return item

        case .workflowZoomReset:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reset Zoom"
            item.paletteLabel = "Reset Zoom"
            item.toolTip = "Reset zoom to 100%"
            item.image = NSImage(systemSymbolName: "1.magnifyingglass", accessibilityDescription: "Reset Zoom")
            item.target = self
            item.action = #selector(resetZoom(_:))
            return item

        case .workflowGridToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Grid"
            item.paletteLabel = "Toggle Grid"
            item.toolTip = "Toggle grid visibility"
            item.image = NSImage(systemSymbolName: "grid", accessibilityDescription: "Toggle Grid")
            item.target = self
            item.action = #selector(toggleGridAction(_:))
            return item

        case .workflowSnapToggle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Snap"
            item.paletteLabel = "Snap to Grid"
            item.toolTip = "Toggle snap to grid"
            item.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "Snap to Grid")
            item.target = self
            item.action = #selector(toggleSnapAction(_:))
            return item

        case .workflowExport:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Export"
            item.paletteLabel = "Export Workflow"
            item.toolTip = "Export workflow to Nextflow or Snakemake"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")

            let menu = NSMenu()
            menu.addItem(withTitle: "Export to Nextflow...", action: #selector(exportNextflowAction(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Export to Snakemake...", action: #selector(exportSnakemakeAction(_:)), keyEquivalent: "")

            item.menu = menu
            item.showsIndicator = true

            return item

        default:
            return nil
        }
    }

    // MARK: - Toolbar Actions

    @objc private func zoomIn(_ sender: Any?) {
        canvasViewController.canvasView.zoomIn()
    }

    @objc private func zoomOut(_ sender: Any?) {
        canvasViewController.canvasView.zoomOut()
    }

    @objc private func resetZoom(_ sender: Any?) {
        canvasViewController.canvasView.resetZoom()
    }

    @objc private func toggleGridAction(_ sender: Any?) {
        toggleGrid()
    }

    @objc private func toggleSnapAction(_ sender: Any?) {
        toggleSnapToGrid()
    }

    @objc private func exportNextflowAction(_ sender: Any?) {
        exportToNextflow()
    }

    @objc private func exportSnakemakeAction(_ sender: Any?) {
        exportToSnakemake()
    }
}

// MARK: - NSToolbarItem.Identifier Extensions

public extension NSToolbarItem.Identifier {
    static let workflowZoomIn = NSToolbarItem.Identifier("workflowZoomIn")
    static let workflowZoomOut = NSToolbarItem.Identifier("workflowZoomOut")
    static let workflowZoomReset = NSToolbarItem.Identifier("workflowZoomReset")
    static let workflowGridToggle = NSToolbarItem.Identifier("workflowGridToggle")
    static let workflowSnapToggle = NSToolbarItem.Identifier("workflowSnapToggle")
    static let workflowExport = NSToolbarItem.Identifier("workflowExport")
}

// MARK: - Child View Controllers

/// View controller wrapper for the node palette.
@MainActor
private class WorkflowNodePaletteViewController: NSViewController {

    let palette = WorkflowNodePalette()

    override func loadView() {
        view = palette
    }
}

/// View controller wrapper for the canvas.
@MainActor
class WorkflowCanvasViewController: NSViewController {

    let canvasView = WorkflowCanvasView()

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.documentView = canvasView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // Set large canvas size
        canvasView.frame = NSRect(x: 0, y: 0, width: 4000, height: 4000)

        view = scrollView
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        canvasView.centerContent()
    }
}

// MARK: - Menu Actions

extension WorkflowBuilderViewController {

    /// Validates menu items.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performUndo(_:)):
            return canvasViewController.canvasView.undoManager?.canUndo ?? false
        case #selector(performRedo(_:)):
            return canvasViewController.canvasView.undoManager?.canRedo ?? false
        case #selector(performDelete(_:)):
            return true // Could check if anything is selected
        default:
            return true
        }
    }

    @objc func performUndo(_ sender: Any?) {
        canvasViewController.canvasView.undoManager?.undo()
    }

    @objc func performRedo(_ sender: Any?) {
        canvasViewController.canvasView.undoManager?.redo()
    }

    @objc func performDelete(_ sender: Any?) {
        canvasViewController.canvasView.deleteSelection()
    }
}
