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

    /// Project workflow library and node palette sidebar.
    private var sidebarViewController: WorkflowBuilderSidebarViewController!

    /// The main canvas.
    private var canvasViewController: WorkflowCanvasViewController!

    /// Inspector for the selected workflow node.
    private var inspectorViewController: WorkflowNodeInspectorViewController!

    // MARK: - Split View Items

    private var paletteItem: NSSplitViewItem!
    private var canvasItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!

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

    /// Active project context used to bind the pinned project output anchor.
    public var activeProjectURL: URL?

    /// Preferred sample context used to preselect the pinned sample input anchor.
    public var preferredSampleURL: URL?

    private var workflowLibraryEntries: [WorkflowLibraryEntry] = []

    private static let workflowBundleType = UTType(exportedAs: "org.lungfish.workflow", conformingTo: .package)

    public var workflowVersionDisplayText: String {
        "v\(graph.version)"
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()

        configureSplitView()
        configureChildControllers()
        configureToolbar()
        setupNotifications()
        reloadWorkflowLibrary()

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
        // Create project workflow library and palette sidebar.
        sidebarViewController = WorkflowBuilderSidebarViewController()
        sidebarViewController.libraryView.onSelectWorkflow = { [weak self] entry in
            self?.selectWorkflowLibraryEntry(entry)
        }
        sidebarViewController.libraryView.onCreateWorkflow = { [weak self] in
            self?.createWorkflowInLibrary()
        }
        sidebarViewController.libraryView.onDuplicateWorkflow = { [weak self] in
            self?.duplicateSelectedWorkflowInLibrary()
        }
        sidebarViewController.libraryView.onDeleteWorkflow = { [weak self] in
            self?.deleteSelectedWorkflowInLibrary()
        }

        // Create canvas view controller
        canvasViewController = WorkflowCanvasViewController()
        canvasViewController.canvasView.delegate = self

        // Create inspector view controller
        inspectorViewController = WorkflowNodeInspectorViewController()
        inspectorViewController.inspector.onNodeChanged = { [weak self] updated in
            guard let self else { return }
            try? self.canvasViewController.canvasView.updateSelectedNode { node in
                node = updated
            }
        }

        // Create split view items
        paletteItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        paletteItem.canCollapse = true
        paletteItem.minimumThickness = 200
        paletteItem.maximumThickness = 300
        paletteItem.preferredThicknessFraction = 0.2

        canvasItem = NSSplitViewItem(viewController: canvasViewController)
        canvasItem.canCollapse = false
        canvasItem.minimumThickness = 400

        inspectorItem = NSSplitViewItem(viewController: inspectorViewController)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 360
        inspectorItem.preferredThicknessFraction = 0.25

        addSplitViewItem(paletteItem)
        addSplitViewItem(canvasItem)
        addSplitViewItem(inspectorItem)
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

    @objc public func windowDidBecomeMain(_ notification: Notification) {
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
        panel.allowedContentTypes = Self.workflowContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.message = "Select a Lungfish workflow bundle or workflow JSON file"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadWorkflow(from: url)
        }
    }

    /// Loads a workflow from the specified URL.
    public func loadWorkflow(from url: URL) {
        do {
            try loadWorkflowOrThrow(from: url)

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

    private func loadWorkflowOrThrow(from url: URL) throws {
        let loadedGraph = try WorkflowLibraryStore.loadWorkflow(from: url)
        graph = loadedGraph
        workflowURL = url.pathExtension.lowercased() == "json" ? url.standardizedFileURL : WorkflowLibraryStore.normalizedWorkflowBundleURL(for: url)
        hasUnsavedChanges = false
        reloadWorkflowLibrary()
        updateWindowTitle()
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
        panel.allowedContentTypes = Self.workflowContentTypes
        panel.nameFieldStringValue = "\(graph.name).lungfishflow"
        panel.message = "Save workflow as"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveWorkflow(to: url)
        }
    }

    private func saveWorkflow(to url: URL) {
        do {
            let savedURL: URL
            if url.pathExtension.lowercased() == "json" {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(graph)
                try data.write(to: url, options: .atomic)
                workflowURL = url
                savedURL = url
            } else {
                savedURL = try saveWorkflowBundle(to: url)
            }

            hasUnsavedChanges = false
            reloadWorkflowLibrary()
            updateWindowTitle()

            logger.info("Saved workflow to: \(savedURL.path)")
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

    @discardableResult
    public func saveWorkflowBundleForTesting(to url: URL) throws -> URL {
        try saveWorkflowBundle(to: url)
    }

    @discardableResult
    private func saveWorkflowBundle(to requestedURL: URL) throws -> URL {
        let bundleURL = try WorkflowLibraryStore.saveWorkflow(graph, to: requestedURL)
        workflowURL = bundleURL
        reloadWorkflowLibrary()
        return bundleURL
    }

    @objc public func runWorkflow(_ sender: Any?) {
        let issues = graph.validate()
        if issues.contains(where: { $0.severity == .error }) {
            let alert = NSAlert()
            alert.messageText = "Workflow Not Ready"
            alert.informativeText = issues.map(\.description).joined(separator: "\n")
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            presentAlert(alert)
            return
        }

        guard let projectURL = activeProjectURL else {
            let alert = NSAlert()
            alert.messageText = "No Active Project"
            alert.informativeText = "Open a Lungfish project before running a workflow so project-relative inputs and outputs can be resolved."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            presentAlert(alert)
            return
        }

        if graph.allNodes.contains(where: { $0.type == .fastqBundleInput }) {
            guard let inputBundleURL = explicitFASTQBundleInputURL(projectURL: projectURL) else {
                let alert = NSAlert()
                alert.messageText = "Input Bundle Not Ready"
                alert.informativeText = "Select a .lungfishfastq bundle on the FASTQ Bundle Input node before running this workflow."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                presentAlert(alert)
                return
            }
            startWorkflowRun(sampleURL: inputBundleURL, projectURL: projectURL)
            return
        }

        let samples = WorkflowBuilderRunSampleDiscovery.discoverSamples(
            in: projectURL,
            preferredSampleURL: preferredSampleURL
        )
        guard !samples.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Sample Inputs Found"
            alert.informativeText = "Import or select a Lungfish sample bundle in the active project before running this workflow."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            presentAlert(alert)
            return
        }

        showRunBindingSheet(samples: samples, projectURL: projectURL)
    }

    public func explicitFASTQBundleInputURLForTesting(projectURL: URL) -> URL? {
        explicitFASTQBundleInputURL(projectURL: projectURL)
    }

    public func configureRunContext(projectURL: URL?, preferredSampleURL: URL?) {
        activeProjectURL = projectURL?.standardizedFileURL
        self.preferredSampleURL = preferredSampleURL?.standardizedFileURL
        reloadWorkflowLibrary()
        inspectorViewController?.inspector.inspect(
            node: canvasViewController?.canvasView.selectedNodeForInspection,
            activeProjectURL: activeProjectURL
        )
    }

    public func createWorkflowInLibraryForTesting(named name: String) throws -> URL {
        try createWorkflowInLibrary(named: name)
    }

    public func duplicateSelectedWorkflowInLibraryForTesting() throws -> URL {
        try duplicateSelectedWorkflowInLibraryOrThrow()
    }

    public func deleteSelectedWorkflowInLibraryForTesting() throws {
        try deleteSelectedWorkflowInLibrary(confirm: false)
    }

    private func reloadWorkflowLibrary() {
        guard isViewLoaded, sidebarViewController != nil else { return }
        do {
            if let activeProjectURL {
                workflowLibraryEntries = try WorkflowLibraryStore.listWorkflows(in: activeProjectURL)
            } else {
                workflowLibraryEntries = []
            }
            sidebarViewController.libraryView.setEntries(workflowLibraryEntries, selectedBundleURL: workflowURL)
        } catch {
            workflowLibraryEntries = []
            sidebarViewController.libraryView.setEntries([], selectedBundleURL: nil)
            logger.error("Failed to reload workflow library: \(error.localizedDescription)")
        }
    }

    private func selectWorkflowLibraryEntry(_ entry: WorkflowLibraryEntry) {
        do {
            try persistDirtyWorkflowBeforeLibraryMutation()
            try loadWorkflowOrThrow(from: entry.bundleURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Open Workflow"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            presentAlert(alert)
        }
    }

    private func createWorkflowInLibrary() {
        do {
            _ = try createWorkflowInLibrary(named: "New Workflow")
        } catch {
            presentLibraryError(error, title: "Failed to Create Workflow")
        }
    }

    @discardableResult
    private func createWorkflowInLibrary(named name: String) throws -> URL {
        guard let activeProjectURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Open a Lungfish project before creating a workflow."])
        }
        try persistDirtyWorkflowBeforeLibraryMutation()
        let newGraph = WorkflowGraph(name: name)
        let bundleURL = try WorkflowLibraryStore.createWorkflow(newGraph, in: activeProjectURL)
        graph = newGraph
        workflowURL = bundleURL
        hasUnsavedChanges = false
        reloadWorkflowLibrary()
        updateWindowTitle()
        return bundleURL
    }

    private func duplicateSelectedWorkflowInLibrary() {
        do {
            _ = try duplicateSelectedWorkflowInLibraryOrThrow()
        } catch {
            presentLibraryError(error, title: "Failed to Duplicate Workflow")
        }
    }

    @discardableResult
    private func duplicateSelectedWorkflowInLibraryOrThrow() throws -> URL {
        guard let activeProjectURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Open a Lungfish project before duplicating a workflow."])
        }
        let selectedSourceURL = sidebarViewController.libraryView.selectedEntry?.bundleURL ?? workflowURL
        try persistDirtyWorkflowBeforeLibraryMutation()
        guard let sourceURL = selectedSourceURL ?? workflowURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Select a workflow to duplicate."])
        }
        let duplicateURL = try WorkflowLibraryStore.duplicateWorkflow(at: sourceURL, in: activeProjectURL)
        try loadWorkflowOrThrow(from: duplicateURL)
        return duplicateURL
    }

    private func persistDirtyWorkflowBeforeLibraryMutation() throws {
        guard hasUnsavedChanges else { return }
        if let workflowURL {
            _ = try saveWorkflowBundle(to: workflowURL)
        } else if let activeProjectURL {
            workflowURL = try WorkflowLibraryStore.createWorkflow(graph, in: activeProjectURL)
            reloadWorkflowLibrary()
        }
        hasUnsavedChanges = false
        updateWindowTitle()
    }

    private func deleteSelectedWorkflowInLibrary() {
        do {
            try deleteSelectedWorkflowInLibrary(confirm: true)
        } catch {
            presentLibraryError(error, title: "Failed to Delete Workflow")
        }
    }

    private func deleteSelectedWorkflowInLibrary(confirm: Bool) throws {
        guard let selectedURL = sidebarViewController.libraryView.selectedEntry?.bundleURL ?? workflowURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Select a workflow to delete."])
        }
        if confirm {
            let alert = NSAlert()
            alert.messageText = "Delete Workflow?"
            alert.informativeText = "This removes \(selectedURL.lastPathComponent) from the project workflow library."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let deletingCurrentWorkflow = workflowURL?.standardizedFileURL.path == selectedURL.standardizedFileURL.path
        try WorkflowLibraryStore.deleteWorkflow(at: selectedURL)
        if deletingCurrentWorkflow {
            graph = WorkflowGraph(name: "New Workflow")
            workflowURL = nil
            hasUnsavedChanges = false
            updateWindowTitle()
        }
        reloadWorkflowLibrary()
    }

    private func presentLibraryError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        presentAlert(alert)
    }

    private func showRunBindingSheet(samples: [WorkflowBuilderRunSample], projectURL: URL) {
        let popup = NSPopUpButton(frame: NSRect(x: 92, y: 38, width: 360, height: 26), pullsDown: false)
        popup.setAccessibilityIdentifier("WorkflowBuilderRunSamplePopup")
        for sample in samples {
            popup.addItem(withTitle: sample.displayName)
            popup.lastItem?.representedObject = sample.url
        }

        let sampleLabel = NSTextField(labelWithString: "Sample:")
        sampleLabel.frame = NSRect(x: 0, y: 42, width: 80, height: 18)
        let projectLabel = NSTextField(labelWithString: "Project:")
        projectLabel.frame = NSRect(x: 0, y: 8, width: 80, height: 18)
        let projectValue = NSTextField(labelWithString: projectURL.lastPathComponent)
        projectValue.frame = NSRect(x: 92, y: 6, width: 360, height: 22)
        projectValue.lineBreakMode = .byTruncatingMiddle

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 452, height: 72))
        accessoryView.addSubview(sampleLabel)
        accessoryView.addSubview(popup)
        accessoryView.addSubview(projectLabel)
        accessoryView.addSubview(projectValue)

        let alert = NSAlert()
        alert.messageText = "Run Workflow"
        alert.informativeText = "Bind the pinned Sample input and Project output anchors before dispatching this workflow."
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn,
                      let sampleURL = popup.selectedItem?.representedObject as? URL else { return }
                self?.startWorkflowRun(sampleURL: sampleURL, projectURL: projectURL)
            }
        } else {
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn,
                  let sampleURL = popup.selectedItem?.representedObject as? URL else { return }
            startWorkflowRun(sampleURL: sampleURL, projectURL: projectURL)
        }
    }

    private func startWorkflowRun(sampleURL: URL, projectURL: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let bundleURL = try self.ensureWorkflowBundleForRun(projectURL: projectURL)
                let binding = WorkflowBuilderRunBinding(sampleURL: sampleURL, projectURL: projectURL)
                _ = try await WorkflowBuilderRunService().run(
                    graph: self.graph,
                    workflowBundleURL: bundleURL,
                    binding: binding
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "Workflow Run Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                self.presentAlert(alert)
            }
        }
    }

    private func explicitFASTQBundleInputURL(projectURL: URL) -> URL? {
        guard let inputNode = graph.allNodes.first(where: { $0.type == .fastqBundleInput }),
              let rawPath = inputNode.parameters["bundle_path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }

        let project = projectURL.standardizedFileURL
        let candidate: URL
        if rawPath.hasPrefix("@/") {
            candidate = project.appendingPathComponent(String(rawPath.dropFirst(2))).standardizedFileURL
        } else {
            candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        }

        let projectPath = project.resolvingSymlinksInPath().standardizedFileURL.path
        let targetPath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let normalizedProjectPath = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"
        guard targetPath.hasPrefix(normalizedProjectPath) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              candidate.pathExtension.lowercased() == "lungfishfastq" else {
            return nil
        }
        return candidate
    }

    private func ensureWorkflowBundleForRun(projectURL: URL) throws -> URL {
        if let workflowURL {
            return try saveWorkflowBundle(to: workflowURL)
        }

        let bundleURL = try WorkflowLibraryStore.createWorkflow(graph, in: projectURL)
        workflowURL = bundleURL
        reloadWorkflowLibrary()
        return bundleURL
    }

    private func presentAlert(_ alert: NSAlert) {
        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
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
        view.window?.subtitle = "\(graph.name) \(workflowVersionDisplayText)"
        if hasUnsavedChanges {
            view.window?.isDocumentEdited = true
        } else {
            view.window?.isDocumentEdited = false
        }
    }

    private static var workflowContentTypes: [UTType] {
        [workflowBundleType, .json]
    }
}

// MARK: - WorkflowCanvasViewDelegate

extension WorkflowBuilderViewController: WorkflowCanvasViewDelegate {

    public func canvasView(_ canvasView: WorkflowCanvasView, didSelectNode node: WorkflowNode?) {
        inspectorViewController.inspector.inspect(node: node, activeProjectURL: activeProjectURL)
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

// MARK: - NSWindowDelegate

extension WorkflowBuilderViewController: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges else {
            return true
        }

        let alert = NSAlert()
        alert.messageText = "Save changes to current workflow?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveWorkflow()
            return !hasUnsavedChanges
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }
}

// MARK: - NSToolbarDelegate

extension WorkflowBuilderViewController: NSToolbarDelegate {

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .workflowRun,
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
            .workflowRun,
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
        case .workflowRun:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Run"
            item.paletteLabel = "Run Workflow"
            item.toolTip = "Validate and run the workflow"
            item.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run Workflow")
            item.target = self
            item.action = #selector(runWorkflow(_:))
            return item

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
    static let workflowRun = NSToolbarItem.Identifier("workflowRun")
    static let workflowZoomOut = NSToolbarItem.Identifier("workflowZoomOut")
    static let workflowZoomReset = NSToolbarItem.Identifier("workflowZoomReset")
    static let workflowGridToggle = NSToolbarItem.Identifier("workflowGridToggle")
    static let workflowSnapToggle = NSToolbarItem.Identifier("workflowSnapToggle")
    static let workflowExport = NSToolbarItem.Identifier("workflowExport")
}

// MARK: - Child View Controllers

/// View controller wrapper for the project workflow library and node palette.
@MainActor
private class WorkflowBuilderSidebarViewController: NSViewController {

    let libraryView = WorkflowLibraryView()
    let palette = WorkflowNodePalette()

    override func loadView() {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .width
        container.spacing = 0

        let separator = NSBox()
        separator.boxType = .separator

        container.addArrangedSubview(libraryView)
        container.addArrangedSubview(separator)
        container.addArrangedSubview(palette)

        libraryView.heightAnchor.constraint(equalToConstant: 190).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        palette.setContentHuggingPriority(.defaultLow, for: .vertical)

        view = container
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

/// View controller wrapper for the selected node inspector.
@MainActor
private class WorkflowNodeInspectorViewController: NSViewController {

    let inspector = WorkflowNodeInspectorView()

    override func loadView() {
        view = inspector
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
            return canvasViewController.canvasView.hasDeletableSelection
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
