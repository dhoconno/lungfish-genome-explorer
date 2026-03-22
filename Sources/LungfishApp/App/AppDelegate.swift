// AppDelegate.swift - Application lifecycle management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers
import os

private let appDelegateLogger = Logger(subsystem: LogSubsystem.app, category: "AppDelegate")

/// Debug logging using os.log (replaces file-based debugLog)
private func debugLog(_ message: String) {
    appDelegateLogger.debug("\(message, privacy: .public)")
}

/// Schedules a MainActor-isolated block to execute on the main run loop.
///
/// This function is critical for Swift concurrency integration with AppKit modal sessions.
/// During sheet dismissal and other modal transitions, both `Task { }` and `DispatchQueue.main.async`
/// may be blocked because GCD's main queue serialization can be stalled.
///
/// The solution is to use CFRunLoopPerformBlock directly with kCFRunLoopCommonModes,
/// which bypasses GCD and schedules directly to the run loop.
///
/// - Parameter block: The MainActor-isolated block to execute
private func scheduleOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    // Use CFRunLoopPerformBlock directly - this bypasses GCD completely
    // and schedules the block directly to the main run loop
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        // We're on main thread via CFRunLoop, safe to assume MainActor
        MainActor.assumeIsolated {
            block()
        }
    }
    // Wake up the run loop to process the block immediately
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

/// Result of loading file data on a background thread using GCD sync pattern.
/// This struct contains only Sendable data that can be safely passed between threads.
/// Note: This is separate from DocumentLoader.FileLoadResult which uses async/await.
private struct SyncFileLoadResult: Sendable {
    let url: URL
    let type: DocumentType
    let sequences: [Sequence]
    let annotations: [SequenceAnnotation]
    let error: String?

    init(url: URL, type: DocumentType, sequences: [Sequence] = [], annotations: [SequenceAnnotation] = [], error: String? = nil) {
        self.url = url
        self.type = type
        self.sequences = sequences
        self.annotations = annotations
        self.error = error
    }
}

/// Main-thread import tracking state used by File > Import.
///
/// This object is captured by notification handlers that are `@Sendable`.
/// The handler immediately hops to `MainActor` before mutating state.
private final class ImportCompletionTracker: @unchecked Sendable {
    var pendingURLs: Set<URL>
    var succeeded: Int = 0
    var failed: Int = 0
    var observerToken: NSObjectProtocol?

    init(urls: [URL]) {
        self.pendingURLs = Set(urls)
    }
}

/// Loads file data synchronously on a background thread, completely avoiding MainActor.
///
/// This is critical for loading files during modal transitions when MainActor is blocked.
/// The function reads and parses the file entirely on a GCD background thread, then calls
/// the completion handler with the parsed data.
///
/// - Parameters:
///   - url: The file URL to load
///   - completion: Called on the main run loop with the load result
private func loadFileInBackground(at url: URL, completion: @escaping @Sendable (SyncFileLoadResult) -> Void) {
    debugLog("loadFileInBackground: Starting for \(url.path)")

    DispatchQueue.global(qos: .userInitiated).async {
        debugLog("loadFileInBackground: Background thread starting")

        // Detect document type
        guard let type = DocumentType.detect(from: url) else {
            debugLog("loadFileInBackground: Unsupported format \(url.pathExtension)")
            completion(SyncFileLoadResult(url: url, type: .fasta, error: "Unsupported file format: \(url.pathExtension)"))
            return
        }

        debugLog("loadFileInBackground: Detected type \(type.rawValue)")

        do {
            var sequences: [Sequence] = []
            var annotations: [SequenceAnnotation] = []

            switch type {
            case .fasta:
                debugLog("loadFileInBackground: Reading FASTA synchronously")
                sequences = try loadFASTASync(from: url)
                debugLog("loadFileInBackground: FASTA loaded \(sequences.count) sequences")

            case .genbank:
                debugLog("loadFileInBackground: Reading GenBank synchronously")
                let records = try loadGenBankSync(from: url)
                for record in records {
                    sequences.append(record.sequence)
                    annotations.append(contentsOf: record.annotations)
                }
                debugLog("loadFileInBackground: GenBank loaded \(sequences.count) sequences, \(annotations.count) annotations")

            default:
                debugLog("loadFileInBackground: Type \(type.rawValue) not yet supported for background loading")
                completion(SyncFileLoadResult(url: url, type: type, error: "Format not supported for this operation"))
                return
            }

            debugLog("loadFileInBackground: Success - sequences=\(sequences.count), annotations=\(annotations.count)")
            completion(SyncFileLoadResult(url: url, type: type, sequences: sequences, annotations: annotations))

        } catch {
            debugLog("loadFileInBackground: Error - \(error.localizedDescription)")
            completion(SyncFileLoadResult(url: url, type: type, error: error.localizedDescription))
        }
    }
}

/// Loads FASTA file synchronously (no async/await, no MainActor).
private func loadFASTASync(from url: URL) throws -> [Sequence] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    guard let data = try handle.readToEnd() else {
        return []
    }

    guard let content = String(data: data, encoding: .utf8) else {
        throw FASTAError.invalidEncoding
    }

    var sequences: [Sequence] = []
    var currentName: String?
    var currentDescription: String?
    var currentBases = ""

    for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)

        if trimmedLine.isEmpty {
            continue
        }

        if trimmedLine.hasPrefix(">") {
            // Save previous sequence if exists
            if let name = currentName, !currentBases.isEmpty {
                let seq = try Sequence(
                    name: name,
                    description: currentDescription,
                    alphabet: detectAlphabet(currentBases),
                    bases: currentBases
                )
                sequences.append(seq)
            }

            // Parse new header
            let headerLine = String(trimmedLine.dropFirst())
            let parts = headerLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            currentName = String(parts.first ?? "")
            currentDescription = parts.count > 1 ? String(parts[1]) : nil
            currentBases = ""

        } else if currentName != nil {
            currentBases += trimmedLine
        }
    }

    // Don't forget the last sequence
    if let name = currentName, !currentBases.isEmpty {
        let seq = try Sequence(
            name: name,
            description: currentDescription,
            alphabet: detectAlphabet(currentBases),
            bases: currentBases
        )
        sequences.append(seq)
    }

    return sequences
}

/// Detects sequence alphabet from bases string.
private func detectAlphabet(_ bases: String) -> SequenceAlphabet {
    let upper = bases.uppercased()

    // Check for protein-specific amino acids
    let proteinOnly = Set("EFILPQZ")
    for char in upper {
        if proteinOnly.contains(char) {
            return .protein
        }
    }

    // Check for U (RNA) vs T (DNA)
    let hasU = upper.contains("U")
    let hasT = upper.contains("T")

    if hasU && !hasT {
        return .rna
    }

    return .dna
}

/// Loads GenBank file synchronously (no async/await, no MainActor).
private func loadGenBankSync(from url: URL) throws -> [GenBankRecord] {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    guard let data = try handle.readToEnd() else {
        return []
    }

    guard let content = String(data: data, encoding: .utf8) else {
        throw GenBankError.invalidEncoding
    }

    // Use the GenBankParser to parse the content synchronously
    let parser = GenBankParser()
    return try parser.parseContent(content)
}

/// Main application delegate handling app lifecycle and global state.
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate,
    FileMenuActions, ViewMenuActions, SequenceMenuActions, ToolsMenuActions, OperationsMenuActions, HelpMenuActions {

    /// The shared application delegate instance
    public static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// Main window controller for the application
    public var mainWindowController: MainWindowController?

    /// All open main windows (strong references for multi-project workflows).
    private var mainWindowControllers: [MainWindowController] = []

    /// Welcome window controller for project selection
    private var welcomeWindowController: WelcomeWindowController?

    /// Settings window controller (lazy singleton)
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?

    /// AI assistant service (lazy singleton), hosted inside Inspector.
    private var aiAssistantService: AIAssistantService?
    private var helpWindowController: HelpWindowController?

    /// AI tool registry for the assistant
    private var aiToolRegistry: AIToolRegistry?

    /// Current working directory for downloads when no project is active
    private var workingDirectoryURL: URL?

    /// Last applied temp retention setting in hours.
    private var lastAppliedTempRetentionHours: Int = 24

    private struct VCFImportHelperEvent: Decodable {
        let event: String
        let progress: Double?
        let message: String?
        let variantCount: Int?
        let error: String?
        let profile: String?
    }

    /// Public accessor for working directory URL
    public func getWorkingDirectoryURL() -> URL? {
        return workingDirectoryURL
    }

    // MARK: - Application Lifecycle

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Install the main menu before app finishes launching
        NSApp.mainMenu = MainMenu.createMainMenu()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Load persisted settings
        AppSettings.load()
        lastAppliedTempRetentionHours = AppSettings.shared.tempFileRetentionHours

        // Register for system notifications
        registerNotifications()

        // Clean up stale temp files from previous sessions
        Task {
            await TempFileManager.shared.setMaxAge(hours: AppSettings.shared.tempFileRetentionHours)
            await TempFileManager.shared.cleanupOnLaunch()
        }

        // Wire up DownloadCenter to handle bundle import when downloads complete.
        // This is the primary mechanism for getting built bundles into the sidebar
        // after background downloads finish. It replaces the fragile callback chain
        // through sheet controllers that get deallocated on dismissal.
        DownloadCenter.shared.onBundleReady = { [weak self] bundleURLs in
            debugLog("DownloadCenter.onBundleReady: Received \(bundleURLs.count) bundle(s)")
            self?.handleMultipleDownloadsSync(bundleURLs)
        }

        // Check for command-line arguments
        let args = ProcessInfo.processInfo.arguments

        // Check for --test-folder argument for automated testing
        if let folderIndex = args.firstIndex(of: "--test-folder"),
           folderIndex + 1 < args.count {
            let folderPath = args[folderIndex + 1]

            // Skip welcome window for automated testing
            showMainWindowWithProject(URL(fileURLWithPath: folderPath))
            return
        }

        // Check for --skip-welcome argument
        if args.contains("--skip-welcome") {
            showMainWindowWithoutProject()
            return
        }

        // Show welcome window for normal launch
        showWelcomeWindow()
    }

    /// Fallback import entry point for callers that have bundle URLs but cannot
    /// rely on DownloadCenter callback wiring (e.g. alternate app startup paths).
    func importReadyBundles(_ bundleURLs: [URL]) {
        handleMultipleDownloadsSync(bundleURLs)
    }

    /// Returns true when `url` is inside `directory`, using resolved paths
    /// (symlink-aware) and path-component prefix matching.
    private func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }

    /// Ensures the sidebar is scoped to the project containing `url` (or a safe
    /// fallback folder), then refreshes and selects the item.
    private func refreshSidebarAndSelectImportedURL(_ url: URL) {
        guard let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController else { return }

        let targetRoot: URL?
        if let projectURL = DocumentManager.shared.activeProject?.url, isURL(url, inside: projectURL) {
            targetRoot = projectURL
        } else if let workingURL = workingDirectoryURL, isURL(url, inside: workingURL) {
            targetRoot = workingURL
        } else if let sidebarProject = sidebarController.currentProjectURL, isURL(url, inside: sidebarProject) {
            targetRoot = sidebarProject
        } else {
            targetRoot = nil
        }

        if let root = targetRoot {
            if sidebarController.currentProjectURL?.standardizedFileURL != root.standardizedFileURL {
                debugLog("refreshSidebarAndSelectImportedURL: Rebasing sidebar to \(root.path)")
                sidebarController.openProject(at: root)
            }
        } else if sidebarController.currentProjectURL == nil {
            // No project context; mirror disk by showing the containing directory.
            let parent = url.deletingLastPathComponent()
            debugLog("refreshSidebarAndSelectImportedURL: No active project, opening parent \(parent.path)")
            sidebarController.openProject(at: parent)
        }

        sidebarController.reloadFromFilesystem()
        _ = sidebarController.selectItem(forURL: url)
        requestInspectorDocumentModeAfterDownload()
    }

    /// Ensures post-download imports land on the Inspector's Document tab.
    ///
    /// Download/import workflows should default to bundle/document context, not
    /// selection editing context.
    private func requestInspectorDocumentModeAfterDownload() {
        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Welcome Window

    private func showWelcomeWindow() {
        welcomeWindowController = WelcomeWindowController()

        welcomeWindowController?.onProjectSelected = { [weak self] projectURL in
            self?.showMainWindowWithProject(projectURL)
        }

        welcomeWindowController?.onOpenFilesSelected = { [weak self] in
            self?.showMainWindowWithoutProject()
            // Trigger the open dialog after a brief delay to ensure window is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self?.openDocument(nil)
            }
        }

        welcomeWindowController?.show()
    }

    @discardableResult
    private func createAndShowMainWindow() -> MainWindowController {
        let controller = MainWindowController()
        controller.showWindow(nil)
        mainWindowController = controller
        if !mainWindowControllers.contains(where: { $0 === controller }) {
            mainWindowControllers.append(controller)
        }
        return controller
    }

    private func openProject(_ projectURL: URL, in controller: MainWindowController) {
        // Keep global working directory in sync with most recently activated project.
        workingDirectoryURL = projectURL
        mainWindowController = controller

        // Use DocumentManager to preserve project semantics and persisted metadata.
        do {
            let _ = try DocumentManager.shared.openProject(at: projectURL)
            debugLog("openProject: Opened project via DocumentManager")
        } catch {
            debugLog("openProject: Failed via DocumentManager, falling back to filesystem sidebar: \(error.localizedDescription)")
            controller.mainSplitViewController?.sidebarController.openProject(at: projectURL)
        }
    }

    private func showMainWindowWithProject(_ projectURL: URL) {
        let controller = createAndShowMainWindow()

        // Activate the app to ensure menu bar switches properly
        NSApp.activate()

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil

        openProject(projectURL, in: controller)
    }

    private func showMainWindowWithoutProject() {
        _ = createAndShowMainWindow()

        // Activate the app to ensure menu bar switches properly
        NSApp.activate()

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil
    }

    /// Loads project folder contents with proper background threading.
    ///
    /// Three-phase loading flow:
    /// 1. **Scan** - Fast folder scan (synchronous, just reads directory entries)
    /// 2. **Populate** - Populate sidebar immediately with placeholder items
    /// 3. **Load** - Load each file in background, update sidebar as each completes
    ///
    /// This approach follows professional genome browser patterns (IGV, UCSC) and:
    public func applicationWillTerminate(_ notification: Notification) {
        // Save application state
        saveApplicationState()

        // Clean up any temp files created during this session
        // Note: This is synchronous since we're terminating
        Task {
            await TempFileManager.shared.cleanupSessionFiles()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep app running even when all windows are closed (standard macOS behavior)
        return false
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Show main window when dock icon is clicked
        if !flag {
            mainWindowController?.showWindow(nil)
        }
        return true
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        // Ensure the main window is key and the menu bar is properly updated
        // This fixes the issue where the menu bar doesn't switch to the app's menu
        // when returning from another application
        if let mainWindow = mainWindowController?.window, mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - File Handling

    public func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Handle opening files via Finder or drag-drop to dock
        let url = URL(fileURLWithPath: filename)
        return openDocument(at: url)
    }

    public func application(_ sender: NSApplication, openFiles filenames: [String]) {
        // Handle opening multiple files
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            _ = openDocument(at: url)
        }
    }

    // MARK: - Private Methods

    private func registerNotifications() {
        // Register for relevant system notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )

        // Register for annotation update notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationUpdated(_:)),
            name: .annotationUpdated,
            object: nil
        )

        // Register for annotation delete notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationDeleted(_:)),
            name: .annotationDeleted,
            object: nil
        )

        // Register for annotation color applied to type notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationColorAppliedToType(_:)),
            name: .annotationColorAppliedToType,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppSettingsChanged(_:)),
            name: .appSettingsChanged,
            object: nil
        )

        // Register for AI assistant show request
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowAIAssistant(_:)),
            name: .showAIAssistantRequested,
            object: nil
        )

        // Update AI tool registry when a bundle loads
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleDidLoadForAI(_:)),
            name: .bundleDidLoad,
            object: nil
        )

    }

    /// Handles annotation updates from the inspector.
    @objc private func handleAnnotationUpdated(_ notification: Notification) {
        guard let annotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation else {
            return
        }

        let viewerController = mainWindowController?.mainSplitViewController?.viewerController

        // Update in-memory document annotations if available
        if let document = viewerController?.currentDocument,
           let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) {
            document.annotations[index] = annotation
        }

        // Update the viewer (handles both document and bundle mode)
        viewerController?.viewerView.updateAnnotation(annotation)
    }

    /// Handles annotation deletions from the inspector.
    @objc private func handleAnnotationDeleted(_ notification: Notification) {
        guard let annotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation else {
            return
        }

        // Remove the annotation from the current document
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        guard let document = viewerController?.currentDocument else { return }

        // Remove the annotation
        document.annotations.removeAll { $0.id == annotation.id }
        // Refresh the viewer
        viewerController?.viewerView.setAnnotations(document.annotations)
        viewerController?.viewerView.needsDisplay = true
    }

    /// Handles applying a color to all annotations of a specific type.
    ///
    /// Updates all matching annotations in both the document (if loaded) and
    /// the viewer's bundle caches, then triggers a redraw.
    @objc private func handleAnnotationColorAppliedToType(_ notification: Notification) {
        guard let annotationType = notification.userInfo?[NotificationUserInfoKey.annotationType] as? AnnotationType,
              let annotationColor = notification.userInfo?[NotificationUserInfoKey.annotationColor] as? AnnotationColor else {
            return
        }

        let viewerController = mainWindowController?.mainSplitViewController?.viewerController

        // Update in-memory document annotations if available
        if let document = viewerController?.currentDocument {
            for (index, annotation) in document.annotations.enumerated() where annotation.type == annotationType {
                var updated = annotation
                updated.color = annotationColor
                document.annotations[index] = updated
            }
        }

        // Update the viewer (handles both document and bundle mode)
        viewerController?.viewerView.applyColorToType(annotationType, color: annotationColor)

        // The applyColorToType method already schedules a view state save via the
        // viewController reference, so no additional save trigger is needed here.
    }

    /// Applies runtime settings that require service reconfiguration.
    @objc private func handleAppSettingsChanged(_ notification: Notification) {
        let retentionHours = AppSettings.shared.tempFileRetentionHours
        guard retentionHours != lastAppliedTempRetentionHours else { return }
        lastAppliedTempRetentionHours = retentionHours

        Task {
            await TempFileManager.shared.setMaxAge(hours: retentionHours)
            // Apply reduced retention immediately instead of waiting for restart.
            await TempFileManager.shared.cleanupOnLaunch()
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow else { return }

        // Remove closed main windows from our tracked list.
        mainWindowControllers.removeAll { controller in
            controller.window === closedWindow
        }

        if mainWindowController?.window === closedWindow {
            mainWindowController = mainWindowControllers.first(where: { $0.window?.isMainWindow == true }) ?? mainWindowControllers.last
        }
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let controller = window.windowController as? MainWindowController else {
            return
        }

        mainWindowController = controller
        if !mainWindowControllers.contains(where: { $0 === controller }) {
            mainWindowControllers.append(controller)
        }
    }

    private func saveApplicationState() {
        // Persist user preferences and window state
        // UserDefaults auto-saves; no manual synchronize needed
    }

    private func openDocument(at url: URL) -> Bool {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController

        Task { @MainActor in
            // Show progress indicator
            viewerController?.showProgress("Loading \(url.lastPathComponent)...")

            do {
                let document = try await DocumentManager.shared.loadDocument(at: url)
                debugLog("Loaded document: \(document.name) with \(document.sequences.count) sequences")

                // Hide progress and display document
                viewerController?.hideProgress()
                viewerController?.displayDocument(document)
            } catch {
                // Hide progress and show error
                viewerController?.hideProgress()

                let alert = NSAlert()
                alert.messageText = "Failed to Open File"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                if let window = self.mainWindowController?.window ?? NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
        return true
    }

    // MARK: - Menu Actions

    @IBAction func newDocument(_ sender: Any?) {
        // Create new project/document
        mainWindowController?.showWindow(nil)
    }

    @IBAction func openDocument(_ sender: Any?) {
        // Show open panel
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes + [
            .init(filenameExtension: "fq")!,
            .init(filenameExtension: "fastq")!,
            .init(filenameExtension: "gz")!,
            .init(filenameExtension: FASTQBundle.directoryExtension)!,
            .init(filenameExtension: "gb")!,
            .init(filenameExtension: "gbk")!,
            .init(filenameExtension: "gff")!,
            .init(filenameExtension: "gff3")!,
        ]

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    _ = self.openDocument(at: url)
                }
            }
        }
    }

    @IBAction func openProjectFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "Select a Lungfish project folder to open in a new window"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self = self else { return }

            let controller = self.createAndShowMainWindow()
            NSApp.activate()
            self.openProject(url, in: controller)
        }
    }

    @IBAction func showAboutPanel(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.showWindow(sender)
    }

    @IBAction func showPreferences(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    // MARK: - FileMenuActions

    @objc func importFiles(_ sender: Any?) {
        debugLog("importFiles: Menu action triggered")

        // Get current project URL
        guard workingDirectoryURL != nil else {
            // No project open - show alert
            let alert = NSAlert()
            alert.messageText = "No Project Open"
            alert.informativeText = "Please open or create a project before importing files."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.applyLungfishBranding()
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        guard let window = mainWindowController?.window else {
            debugLog("importFiles: No main window available")
            return
        }

        debugLog("importFiles: Showing import dialog")

        // Show import dialog directly using NSOpenPanel
        // We avoid Task{} here because it doesn't execute reliably from @objc menu actions
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.message = "Select files to import into the project"
        panel.prompt = "Import"

        // Use beginSheetModal with completion handler
        panel.beginSheetModal(for: window) { [weak self] response in
            debugLog("importFiles: Panel response: \(response.rawValue)")

            guard response == .OK else {
                debugLog("importFiles: User cancelled")
                return
            }

            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else {
                debugLog("importFiles: No files selected")
                return
            }

            debugLog("importFiles: Selected \(selectedURLs.count) file(s)")

            // Schedule the file copy operation via CFRunLoop to ensure it executes
            // even during modal session transitions
            scheduleOnMainRunLoop {
                guard let self = self else { return }
                debugLog("importFiles: Starting import pipeline dispatch")

                // Get references to UI components
                let activityIndicator = self.mainWindowController?.mainSplitViewController?.activityIndicator

                // Show progress indicator
                let fileCount = selectedURLs.count
                let requestID = UUID().uuidString
                let tracker = ImportCompletionTracker(urls: selectedURLs)
                activityIndicator?.show(
                    message: "Importing \(fileCount) file\(fileCount == 1 ? "" : "s")...",
                    style: .indeterminate
                )

                tracker.observerToken = NotificationCenter.default.addObserver(
                    forName: .sidebarFileDropCompleted,
                    object: nil,
                    queue: .main
                ) { completion in
                    let completionRequestID = completion.userInfo?["requestID"] as? String
                    let completedURL = completion.userInfo?["url"] as? URL
                    let wasSuccessful = (completion.userInfo?["success"] as? Bool) == true

                    Task { @MainActor in
                        guard let completionRequestID,
                              completionRequestID == requestID,
                              let completedURL else {
                            return
                        }
                        guard tracker.pendingURLs.contains(completedURL) else { return }

                        tracker.pendingURLs.remove(completedURL)
                        if wasSuccessful {
                            tracker.succeeded += 1
                        } else {
                            tracker.failed += 1
                        }

                        if tracker.pendingURLs.isEmpty {
                            if let observerToken = tracker.observerToken {
                                NotificationCenter.default.removeObserver(observerToken)
                                tracker.observerToken = nil
                            }
                            activityIndicator?.hide()
                            debugLog(
                                "importFiles: Completed request \(requestID). success=\(tracker.succeeded), failed=\(tracker.failed)"
                            )

                            if tracker.failed > 0 {
                                let alert = NSAlert()
                                alert.messageText = "Import Completed with Errors"
                                alert.informativeText = "\(tracker.succeeded) succeeded, \(tracker.failed) failed."
                                alert.alertStyle = .warning
                                alert.addButton(withTitle: "OK")
                                alert.applyLungfishBranding()
                                if let window = NSApp.keyWindow {
                                    await alert.beginSheetModal(for: window)
                                }
                            }
                        }
                    }
                }

                for (index, sourceURL) in selectedURLs.enumerated() {
                    activityIndicator?.updateMessage("Importing \(sourceURL.lastPathComponent) (\(index + 1)/\(fileCount))...")
                    NotificationCenter.default.post(
                        name: .sidebarFileDropped,
                        object: self,
                        userInfo: ["url": sourceURL, "destination": NSNull(), "requestID": requestID]
                    )
                }

                debugLog("importFiles: Dispatched \(selectedURLs.count) file(s) to sidebar import pipeline")
            }
        }
    }

    @objc func importVCFToBundle(_ sender: Any?) {
        debugLog("importVCFToBundle: Menu action triggered")

        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let bundleURL = viewerController?.currentBundleURL

        guard let window = mainWindowController?.window else {
            debugLog("importVCFToBundle: No main window available")
            return
        }

        // Show NSOpenPanel for VCF files
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var vcfTypes: [UTType] = []
        if let vcfType = UTType(filenameExtension: "vcf") {
            vcfTypes.append(vcfType)
        }
        // .vcf.gz files have UTType for "gz" — include it so they're visible by default
        if let gzType = UTType(filenameExtension: "gz") {
            vcfTypes.append(gzType)
        }
        panel.allowedContentTypes = vcfTypes
        panel.allowsOtherFileTypes = true
        panel.message = bundleURL != nil
            ? "Select VCF file(s) to import into the current bundle"
            : "Select VCF file(s) to open"
        panel.prompt = "Import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else {
                debugLog("importVCFToBundle: User cancelled")
                return
            }
            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else { return }
            debugLog("importVCFToBundle: Selected \(selectedURLs.count) file(s)")

            if let bundleURL {
                // Existing bundle loaded — import into it (use first file for backward compat)
                if let firstURL = selectedURLs.first {
                    self?.performVCFImport(vcfURL: firstURL, bundleURL: bundleURL)
                }
            } else {
                // No bundle loaded — auto-ingest into a new naked bundle
                if let mainSplit = self?.mainWindowController?.mainSplitViewController {
                    mainSplit.loadVCFFilesInBackground(urls: selectedURLs)
                }
            }
        }
    }

    @objc func importBAMToBundle(_ sender: Any?) {
        debugLog("importBAMToBundle: Menu action triggered")

        // Require a bundle to be loaded
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(title: "No Bundle Loaded", message: "Please open a reference genome bundle before importing alignments.")
            return
        }

        guard let window = mainWindowController?.window else {
            debugLog("importBAMToBundle: No main window available")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var bamTypes: [UTType] = []
        for ext in ["bam", "cram", "sam"] {
            if let utType = UTType(filenameExtension: ext) {
                bamTypes.append(utType)
            }
        }
        panel.allowedContentTypes = bamTypes
        panel.allowsOtherFileTypes = true
        panel.message = "Select a BAM, CRAM, or SAM file to import into the current bundle"
        panel.prompt = "Import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let bamURL = panel.url else {
                debugLog("importBAMToBundle: User cancelled")
                return
            }
            debugLog("importBAMToBundle: Selected \(bamURL.lastPathComponent)")
            self?.performBAMImport(bamURL: bamURL, bundleURL: bundleURL)
        }
    }

    @objc func importSampleMetadataToBundle(_ sender: Any?) {
        debugLog("importSampleMetadataToBundle: Menu action triggered")

        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(title: "No Bundle Loaded", message: "Please open a reference genome bundle before importing sample metadata.")
            return
        }

        presentMetadataImportPanel(for: bundleURL, presentingWindow: mainWindowController?.window)
    }

    func presentMetadataImportPanel(for bundleURL: URL, presentingWindow: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
            .init(filenameExtension: "txt")!,
        ]
        panel.message = "Select a TSV or CSV file with sample metadata"
        panel.prompt = "Import Metadata"

        let handleSelection: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let metadataURL = panel.url else {
                debugLog("presentMetadataImportPanel: User cancelled")
                return
            }
            self?.performSampleMetadataImport(metadataURL: metadataURL, bundleURL: bundleURL)
        }

        if let window = presentingWindow ?? mainWindowController?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: handleSelection)
        }
    }

    private func performSampleMetadataImport(metadataURL: URL, bundleURL: URL) {
        debugLog("performSampleMetadataImport: Starting import of \(metadataURL.lastPathComponent) into \(bundleURL.lastPathComponent)")
        let format: MetadataFormat = metadataURL.pathExtension.lowercased() == "csv" ? .csv : .tsv

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let manifest = try BundleManifest.load(from: bundleURL)
                guard !manifest.variants.isEmpty else {
                    throw NSError(
                        domain: "Lungfish",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "This bundle has no variant tracks to apply metadata to."]
                    )
                }

                var totalUpdated = 0
                var updatedTracks = 0

                for track in manifest.variants {
                    guard let databasePath = track.databasePath else {
                        debugLog("performSampleMetadataImport: Skipping track '\(track.name)' (no databasePath)")
                        continue
                    }
                    let dbURL = bundleURL.appendingPathComponent(databasePath)
                    let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                    let updated = try rwDB.importSampleMetadata(from: metadataURL, format: format)
                    totalUpdated += updated
                    updatedTracks += 1
                    debugLog("performSampleMetadataImport: Track '\(track.name)' updated \(updated) rows")
                }

                scheduleOnMainRunLoop { [weak self] in
                    guard let self else { return }
                    debugLog("performSampleMetadataImport: Completed; tracks=\(updatedTracks), rows=\(totalUpdated)")
                    if let viewerController = self.mainWindowController?.mainSplitViewController?.viewerController,
                       viewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                        do {
                            try viewerController.displayBundle(at: bundleURL)
                        } catch {
                            debugLog("performSampleMetadataImport: Bundle reload failed: \(error.localizedDescription)")
                        }
                    }
                    self.showAlert(
                        title: "Metadata Imported",
                        message: "Updated \(totalUpdated.formatted()) sample metadata values across \(updatedTracks) variant track(s)."
                    )
                }
            } catch {
                scheduleOnMainRunLoop { [weak self] in
                    debugLog("performSampleMetadataImport: Failed: \(error.localizedDescription)")
                    self?.showAlert(title: "Metadata Import Failed", message: error.localizedDescription)
                }
            }
        }
    }

    private func performVCFImport(vcfURL: URL, bundleURL: URL) {
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                showAlert(title: "Operation in Progress",
                          message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish.")
            }
            return
        }

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let selectedImportProfile = selectedVCFImportProfile()
        let profileLabel = Self.importProfileLabel(selectedImportProfile)

        let opID = OperationCenter.shared.start(
            title: "Importing \(vcfURL.lastPathComponent)",
            detail: "Importing VCF variants (\(profileLabel))...",
            operationType: .vcfImport,
            targetBundleURL: bundleURL,
            onCancel: { cancelFlag.withLock { $0 = true } }
        )
        let importStartedAt = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            // All file I/O on background thread — no UI references captured
            let result: Result<(variantCount: Int, trackInfo: VariantTrackInfo), Error>
            let isCancelled: @Sendable () -> Bool = { cancelFlag.withLock { $0 } }

            // Compute dbURL before `do` so it's available for cleanup on cancellation
            var baseURL = vcfURL
            if baseURL.pathExtension.lowercased() == "gz" {
                baseURL = baseURL.deletingPathExtension()
            }
            if baseURL.pathExtension.lowercased() == "vcf" {
                baseURL = baseURL.deletingPathExtension()
            }
            let trackId = baseURL.lastPathComponent
            let dbFilename = "\(trackId).db"
            let variantsDir = bundleURL.appendingPathComponent("variants")
            let dbURL = variantsDir.appendingPathComponent(dbFilename)

            do {
                // Create variants directory if needed
                try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)

                let variantCount: Int

                // Check if there's a resumable incomplete import from a previous crash.
                let detectedImportState = VariantDatabase.importState(at: dbURL)
                let dbExists = FileManager.default.fileExists(atPath: dbURL.path)
                debugLog("performVCFImport: dbExists=\(dbExists), importState=\(detectedImportState ?? "nil"), path=\(dbURL.lastPathComponent)")

                func runFreshImport(startedAt: Date) throws -> Int {
                    if FileManager.default.fileExists(atPath: dbURL.path) {
                        try FileManager.default.removeItem(at: dbURL)
                    }

                    debugLog("performVCFImport: Creating variant database at \(dbURL.lastPathComponent) via helper")

                    do {
                        var importedCount = try Self.runVCFImportViaHelper(
                            vcfURL: vcfURL,
                            outputDBURL: dbURL,
                            sourceFile: vcfURL.lastPathComponent,
                            importProfile: selectedImportProfile,
                            shouldCancel: isCancelled,
                            progressHandler: { progress, message in
                                let clampedProgress = max(0.0, min(1.0, progress))
                                let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: startedAt)
                                let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                                scheduleOnMainRunLoop {
                                    OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                                }
                            }
                        )

                        // Staged ultra-low-memory imports intentionally return after insert
                        // phase with import_state=indexing so indexing runs in a fresh process.
                        if VariantDatabase.importState(at: dbURL) == "indexing" {
                            debugLog("performVCFImport: Insert phase complete, launching phase-2 index build helper")
                            let resumeStartedAt = Date()
                            importedCount = try Self.runVCFResumeViaHelper(
                                outputDBURL: dbURL,
                                shouldCancel: isCancelled,
                                progressHandler: { progress, message in
                                    let clampedProgress = max(0.0, min(1.0, progress))
                                    let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: resumeStartedAt)
                                    let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                                    scheduleOnMainRunLoop {
                                        OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                                    }
                                }
                            )
                            debugLog("performVCFImport: Phase-2 index build complete with \(importedCount) variants")
                        }

                        return importedCount
                    } catch {
                        // If helper failed during indexing, inserts are complete and only
                        // index creation needs recovery in a fresh process.
                        if let importState = VariantDatabase.importState(at: dbURL),
                           importState == "indexing" {
                            debugLog("performVCFImport: Helper failed during indexing, auto-resuming index creation...")
                            let resumeStartedAt = Date()
                            let resumedCount = try Self.runVCFResumeViaHelper(
                                outputDBURL: dbURL,
                                shouldCancel: isCancelled,
                                progressHandler: { progress, message in
                                    let clampedProgress = max(0.0, min(1.0, progress))
                                    let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: resumeStartedAt)
                                    let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                                    scheduleOnMainRunLoop {
                                        OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                                    }
                                }
                            )
                            debugLog("performVCFImport: Auto-resume complete with \(resumedCount) variants")
                            return resumedCount
                        }
                        throw error
                    }
                }

                if detectedImportState == "indexing" {
                    debugLog("performVCFImport: Found interrupted indexing phase, resuming via helper")
                    variantCount = try Self.runVCFResumeViaHelper(
                        outputDBURL: dbURL,
                        shouldCancel: isCancelled,
                        progressHandler: { progress, message in
                            let clampedProgress = max(0.0, min(1.0, progress))
                            let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: importStartedAt)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            scheduleOnMainRunLoop {
                                OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                            }
                        }
                    )
                } else if detectedImportState == "inserting" {
                    // Partial row ingest cannot be resumed safely without replaying the VCF.
                    debugLog("performVCFImport: Found interrupted inserting phase, restarting full import from source VCF")
                    variantCount = try runFreshImport(startedAt: importStartedAt)
                } else if VariantDatabase.metadataValue(at: dbURL, key: "materialize_state") == "materializing" {
                    // Import is complete but materialization was interrupted — resume it.
                    debugLog("performVCFImport: Found incomplete materialization, resuming via helper")
                    let importedDB = try VariantDatabase(url: dbURL)
                    variantCount = importedDB.totalCount()

                    let materializeStartedAt = Date()
                    try Self.runVCFMaterializeViaHelper(
                        outputDBURL: dbURL,
                        shouldCancel: isCancelled,
                        progressHandler: { progress, message in
                            let clampedProgress = max(0.0, min(1.0, progress))
                            let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: materializeStartedAt)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            scheduleOnMainRunLoop {
                                OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                            }
                        }
                    )
                    debugLog("performVCFImport: Materialization resume complete")
                } else if dbExists, detectedImportState == nil,
                          VariantDatabase.hasVariantsTable(at: dbURL) {
                    // DB file exists with a variants table but import_state is unreadable
                    // (likely corrupted metadata from a crash). We cannot prove inserts
                    // completed, so rebuild from source VCF.
                    debugLog("performVCFImport: DB has variants table but missing import_state, restarting full import from source VCF")
                    variantCount = try runFreshImport(startedAt: importStartedAt)
                } else {
                    variantCount = try runFreshImport(startedAt: importStartedAt)
                }

                debugLog("performVCFImport: Created database with \(variantCount) variants")
                if isCancelled() {
                    throw VariantDatabaseError.cancelled
                }

                // Normalize chromosome names to match the bundle.
                // Only performs name-based mapping (aliases, chr prefix, version suffix).
                // Length-based matching is deferred to the runtime alias map which uses
                // contig lengths stored in the database — this avoids slow UPDATE statements
                // on very large databases.
                let currentManifestForChrom = try BundleManifest.load(from: bundleURL)
                let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                let vcfChroms = rwDB.allChromosomes()
                let chromMapping = mapVCFChromosomes(vcfChroms, toBundleChromosomes: currentManifestForChrom.genome?.chromosomes ?? [])
                if !chromMapping.isEmpty {
                    try rwDB.renameChromosomes(chromMapping)
                    debugLog("performVCFImport: Remapped chromosomes: \(chromMapping)")
                }
                if isCancelled() {
                    throw VariantDatabaseError.cancelled
                }

                // Materialize variant_info EAV table if it was skipped during
                // ultraLowMemory import.  This runs as a separate helper process
                // with a fresh address space so it cannot OOM the GUI.
                if rwDB.variantInfoSkipped {
                    debugLog("performVCFImport: Variant info was skipped — launching materialization helper")
                    let materializeStartedAt = Date()
                    try Self.runVCFMaterializeViaHelper(
                        outputDBURL: dbURL,
                        shouldCancel: isCancelled,
                        progressHandler: { progress, message in
                            // Map materialization progress to the tail end of the operation
                            let displayProgress = 0.95 + progress * 0.05
                            let clampedProgress = max(0.0, min(1.0, displayProgress))
                            let etaText = Self.estimatedRemainingText(progress: progress, startedAt: materializeStartedAt)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            scheduleOnMainRunLoop {
                                OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                            }
                        }
                    )
                    debugLog("performVCFImport: Materialization complete")
                }

                // Create VariantTrackInfo
                let trackInfo = VariantTrackInfo(
                    id: trackId,
                    name: vcfURL.deletingPathExtension().lastPathComponent,
                    description: "Imported from \(vcfURL.lastPathComponent)",
                    path: "variants/\(trackId).bcf",
                    indexPath: "variants/\(trackId).bcf.csi",
                    databasePath: "variants/\(dbFilename)",
                    variantType: .mixed,
                    variantCount: variantCount,
                    source: "VCF Import"
                )

                // Load current manifest, add track, save
                let currentManifest = try BundleManifest.load(from: bundleURL)

                // Check for duplicate track ID — remove old entry if re-importing
                let filteredVariants = currentManifest.variants.filter { $0.id != trackId }
                let baseManifest: BundleManifest
                if filteredVariants.count != currentManifest.variants.count {
                    baseManifest = BundleManifest(
                        formatVersion: currentManifest.formatVersion,
                        name: currentManifest.name,
                        identifier: currentManifest.identifier,
                        description: currentManifest.description,
                        createdDate: currentManifest.createdDate,
                        modifiedDate: Date(),
                        source: currentManifest.source,
                        genome: currentManifest.genome,
                        annotations: currentManifest.annotations,
                        variants: filteredVariants,
                        tracks: currentManifest.tracks,
                        metadata: currentManifest.metadata
                    )
                } else {
                    baseManifest = currentManifest
                }

                let updatedManifest = baseManifest.addingVariantTrack(trackInfo)
                try updatedManifest.save(to: bundleURL)

                result = .success((variantCount, trackInfo))
            } catch {
                result = .failure(error)
            }

            debugLog("performVCFImport: Background work done, scheduling main thread callback")

            scheduleOnMainRunLoop { [weak self] in
                debugLog("performVCFImport: Main thread callback executing")

                switch result {
                case .success(let (variantCount, _)):
                    OperationCenter.shared.complete(id: opID, detail: "\(variantCount) variants imported")

                    guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                        debugLog("performVCFImport: No viewer controller")
                        return
                    }
                    do {
                        try viewerController.displayBundle(at: bundleURL)
                        debugLog("performVCFImport: Bundle reloaded with \(variantCount) variants")
                    } catch {
                        debugLog("performVCFImport: Bundle reload failed: \(error.localizedDescription)")
                        self?.showAlert(title: "Import Error", message: "VCF imported but bundle reload failed: \(error.localizedDescription)")
                    }

                case .failure(let error):
                    if let dbErr = error as? VariantDatabaseError, case .cancelled = dbErr {
                        try? FileManager.default.removeItem(at: dbURL)
                        debugLog("performVCFImport: Cancelled by user")
                        // cancel() already called fail() via onCancel callback
                    } else {
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        debugLog("performVCFImport: Failed: \(error.localizedDescription)")
                        self?.showAlert(title: "VCF Import Failed", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func selectedVCFImportProfile() -> VCFImportProfile {
        let raw = AppSettings.shared.vcfImportProfile
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .auto }
        if let profile = VCFImportProfile(rawValue: raw) {
            return profile
        }
        switch raw.lowercased() {
        case "fast":
            return .fast
        case "lowmemory", "low-memory", "low_memory":
            return .lowMemory
        case "ultra-low-memory", "ultra_low_memory", "ultralow":
            return .ultraLowMemory
        default:
            return .auto
        }
    }

    private nonisolated static func importProfileLabel(_ profile: VCFImportProfile) -> String {
        switch profile {
        case .auto:
            return "Auto"
        case .lowMemory:
            return "Low Memory"
        case .fast:
            return "Fast"
        case .ultraLowMemory:
            return "Ultra Low Memory"
        }
    }

    private nonisolated static func signalName(forTerminationStatus status: Int32) -> String? {
        switch status {
        case 9:
            return "SIGKILL"
        case 15:
            return "SIGTERM"
        case 6:
            return "SIGABRT"
        case 11:
            return "SIGSEGV"
        case 10:
            return "SIGBUS"
        case 5:
            return "SIGTRAP"
        case 2:
            return "SIGINT"
        default:
            return nil
        }
    }

    private nonisolated static func runVCFImportViaHelper(
        vcfURL: URL,
        outputDBURL: URL,
        sourceFile: String,
        importProfile: VCFImportProfile,
        shouldCancel: @escaping @Sendable () -> Bool,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for helper import")
        }

        let debugLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-vcf-import-\(UUID().uuidString).log")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-import-helper",
            "--vcf-path", vcfURL.path,
            "--output-db-path", outputDBURL.path,
            "--source-file", sourceFile,
            "--import-profile", importProfile.rawValue,
            "--debug-log-path", debugLogURL.path,
        ]
        debugLog(
            "runVCFImportViaHelper: launch helper=\(executablePath) vcf=\(vcfURL.lastPathComponent) db=\(outputDBURL.lastPathComponent) profile=\(importProfile.rawValue) debugLog=\(debugLogURL.path)"
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct HelperParseState: Sendable {
            var stdoutBuffer = Data()
            var helperError: String?
            var variantCount: Int?
            var wasCancelled = false
        }
        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())
        let stderrState = OSAllocatedUnfairLock(initialState: Data())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(VCFImportHelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    debugLog("runVCFImportViaHelper: raw-stdout '\(String(text.prefix(300)))'")
                    parseState.withLock { state in
                        if state.helperError == nil {
                            state.helperError = text
                        }
                    }
                }
                return
            }

            switch event.event {
            case "progress":
                if let progress = event.progress {
                    let msg = event.message ?? "Importing VCF..."
                    debugLog("runVCFImportViaHelper: event=progress p=\(String(format: "%.4f", progress)) msg='\(String(msg.prefix(220)))'")
                    progressHandler(progress, event.message ?? "Importing VCF...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    debugLog("runVCFImportViaHelper: event=done variantCount=\(variantCount)")
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF helper import failed"
                debugLog("runVCFImportViaHelper: event=error '\(String(message.prefix(320)))'")
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                debugLog("runVCFImportViaHelper: event=cancelled")
                parseState.withLock { $0.wasCancelled = true }
            default:
                debugLog("runVCFImportViaHelper: event=\(event.event)")
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }
        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrState.withLock { $0.append(data) }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                debugLog("runVCFImportViaHelper: stderr '\(String(text.prefix(300)))'")
            }
        }

        try process.run()

        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        debugLog(
            "runVCFImportViaHelper: process-exit status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        let helperCancelled = parseState.withLock { $0.wasCancelled }
        if shouldCancel() || helperCancelled {
            debugLog("runVCFImportViaHelper: cancelled by caller/helper")
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let signalSuffix: String
            if process.terminationReason == .uncaughtSignal {
                let signalName = signalName(forTerminationStatus: process.terminationStatus)
                signalSuffix = " (signal \(process.terminationStatus)\(signalName.map { " \($0)" } ?? ""))"
            } else {
                signalSuffix = ""
            }
            let defaultMessage = "VCF helper exited with status \(process.terminationStatus)\(signalSuffix)"
            let baseMessage = helperError ?? (stderrMessage.isEmpty ? defaultMessage : stderrMessage)
            debugLog("runVCFImportViaHelper: failure '\(String(baseMessage.prefix(320)))'")
            let message = "\(baseMessage)\nDebug log: \(debugLogURL.path)"
            throw VariantDatabaseError.createFailed(message)
        }

        if let variantCount = parseState.withLock({ $0.variantCount }) {
            return variantCount
        }

        let importedDB = try VariantDatabase(url: outputDBURL)
        return importedDB.totalCount()
    }

    /// Launch the helper process in `--vcf-resume-helper` mode to finish an
    /// interrupted import (creates missing indexes on an existing database).
    private nonisolated static func runVCFResumeViaHelper(
        outputDBURL: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for helper resume")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-resume-helper",
            "--output-db-path", outputDBURL.path,
        ]
        debugLog("runVCFResumeViaHelper: launch helper=\(executablePath) db=\(outputDBURL.lastPathComponent)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct HelperParseState: Sendable {
            var stdoutBuffer = Data()
            var helperError: String?
            var variantCount: Int?
            var wasCancelled = false
        }
        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(VCFImportHelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    debugLog("runVCFResumeViaHelper: raw-stdout '\(String(text.prefix(300)))'")
                }
                return
            }
            switch event.event {
            case "progress":
                if let progress = event.progress {
                    let msg = event.message ?? "Resuming..."
                    debugLog("runVCFResumeViaHelper: event=progress p=\(String(format: "%.4f", progress)) msg='\(String(msg.prefix(220)))'")
                    progressHandler(progress, event.message ?? "Resuming...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    debugLog("runVCFResumeViaHelper: event=done variantCount=\(variantCount)")
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF resume helper failed"
                debugLog("runVCFResumeViaHelper: event=error '\(String(message.prefix(320)))'")
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                debugLog("runVCFResumeViaHelper: event=cancelled")
                parseState.withLock { $0.wasCancelled = true }
            default:
                debugLog("runVCFResumeViaHelper: event=\(event.event)")
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }

        try process.run()

        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        debugLog(
            "runVCFResumeViaHelper: process-exit status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )

        stdoutHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        let helperCancelled = parseState.withLock { $0.wasCancelled }
        if shouldCancel() || helperCancelled {
            debugLog("runVCFResumeViaHelper: cancelled by caller/helper")
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let message = helperError ?? "VCF resume helper exited with status \(process.terminationStatus)"
            debugLog("runVCFResumeViaHelper: failure '\(String(message.prefix(320)))'")
            throw VariantDatabaseError.createFailed(message)
        }

        if let variantCount = parseState.withLock({ $0.variantCount }) {
            return variantCount
        }

        let resumedDB = try VariantDatabase(url: outputDBURL)
        return resumedDB.totalCount()
    }

    /// Launch the helper process in `--vcf-materialize-helper` mode to populate
    /// the variant_info EAV table from raw INFO strings stored during
    /// ultraLowMemory import.
    @discardableResult
    private nonisolated static func runVCFMaterializeViaHelper(
        outputDBURL: URL,
        shouldCancel: @escaping @Sendable () -> Bool,
        progressHandler: @escaping @Sendable (Double, String) -> Void
    ) throws -> Int {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else {
            throw VariantDatabaseError.createFailed("Could not locate application executable for helper materialize")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-materialize-helper",
            "--output-db-path", outputDBURL.path,
        ]
        debugLog("runVCFMaterializeViaHelper: launch helper=\(executablePath) db=\(outputDBURL.lastPathComponent)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        struct HelperParseState: Sendable {
            var stdoutBuffer = Data()
            var helperError: String?
            var variantCount: Int?
            var wasCancelled = false
        }
        let parseState = OSAllocatedUnfairLock(initialState: HelperParseState())

        let handleEventLine: @Sendable (Data) -> Void = { line in
            guard !line.isEmpty else { return }
            guard let event = try? JSONDecoder().decode(VCFImportHelperEvent.self, from: line) else {
                if let text = String(data: line, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    debugLog("runVCFMaterializeViaHelper: raw-stdout '\(String(text.prefix(300)))'")
                }
                return
            }
            switch event.event {
            case "progress":
                if let progress = event.progress {
                    let msg = event.message ?? "Materializing..."
                    debugLog("runVCFMaterializeViaHelper: event=progress p=\(String(format: "%.4f", progress)) msg='\(String(msg.prefix(220)))'")
                    progressHandler(progress, event.message ?? "Materializing...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    debugLog("runVCFMaterializeViaHelper: event=done variantCount=\(variantCount)")
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF materialize helper failed"
                debugLog("runVCFMaterializeViaHelper: event=error '\(String(message.prefix(320)))'")
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                debugLog("runVCFMaterializeViaHelper: event=cancelled")
                parseState.withLock { $0.wasCancelled = true }
            default:
                debugLog("runVCFMaterializeViaHelper: event=\(event.event)")
                break
            }
        }

        let consumeStdoutData: @Sendable (Data) -> Void = { data in
            guard !data.isEmpty else { return }
            let lines = parseState.withLock { state -> [Data] in
                var parsed: [Data] = []
                state.stdoutBuffer.append(data)
                while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) {
                    let line = Data(state.stdoutBuffer.prefix(upTo: newlineIndex))
                    state.stdoutBuffer.removeSubrange(...newlineIndex)
                    parsed.append(line)
                }
                return parsed
            }
            for line in lines {
                handleEventLine(line)
            }
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            consumeStdoutData(data)
        }

        try process.run()

        while process.isRunning {
            if shouldCancel() {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        debugLog(
            "runVCFMaterializeViaHelper: process-exit status=\(process.terminationStatus) reason=\(process.terminationReason == .uncaughtSignal ? "signal" : "exit")"
        )

        stdoutHandle.readabilityHandler = nil
        consumeStdoutData(stdoutHandle.readDataToEndOfFile())

        if let trailing = parseState.withLock({ state -> Data? in
            guard !state.stdoutBuffer.isEmpty else { return nil }
            defer { state.stdoutBuffer.removeAll(keepingCapacity: false) }
            return state.stdoutBuffer
        }) {
            handleEventLine(trailing)
        }

        let helperCancelled = parseState.withLock { $0.wasCancelled }
        if shouldCancel() || helperCancelled {
            debugLog("runVCFMaterializeViaHelper: cancelled by caller/helper")
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let message = helperError ?? "VCF materialize helper exited with status \(process.terminationStatus)"
            debugLog("runVCFMaterializeViaHelper: failure '\(String(message.prefix(320)))'")
            throw VariantDatabaseError.createFailed(message)
        }

        return parseState.withLock { $0.variantCount } ?? 0
    }

    private nonisolated static func estimatedRemainingText(progress: Double, startedAt: Date) -> String {
        guard progress > 0.01, progress < 1.0 else { return "" }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.5 else { return "" }
        let totalEstimate = elapsed / progress
        let remaining = max(0, totalEstimate - elapsed)
        guard remaining.isFinite else { return "" }

        let rounded = Int(remaining.rounded())
        if rounded < 60 {
            return "ETA ~\(rounded)s"
        }
        let mins = rounded / 60
        let secs = rounded % 60
        return secs == 0 ? "ETA ~\(mins)m" : "ETA ~\(mins)m \(secs)s"
    }

    // MARK: - BAM/CRAM Import

    private func performBAMImport(bamURL: URL, bundleURL: URL) {
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                showAlert(title: "Operation in Progress",
                          message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish.")
            }
            return
        }

        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let opID = OperationCenter.shared.start(
            title: "Importing \(bamURL.lastPathComponent)",
            detail: "Importing alignments...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            onCancel: { cancelFlag.withLock { $0 = true } }
        )
        let importStartedAt = Date()

        Task.detached {
            let result: Result<BAMImportService.ImportResult, Error>
            do {
                let importResult = try await BAMImportService.importBAM(
                    bamURL: bamURL,
                    bundleURL: bundleURL,
                    progressHandler: { progress, message in
                        let clampedProgress = max(0.0, min(1.0, progress))
                        let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: importStartedAt)
                        let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                        scheduleOnMainRunLoop {
                            OperationCenter.shared.update(id: opID, progress: clampedProgress, detail: displayMessage)
                        }
                    }
                )
                result = .success(importResult)
            } catch {
                result = .failure(error)
            }

            scheduleOnMainRunLoop { [weak self] in
                switch result {
                case .success(let importResult):
                    let readCount = importResult.mappedReads + importResult.unmappedReads
                    OperationCenter.shared.complete(id: opID, detail: "\(readCount) reads imported")

                    guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                        debugLog("performBAMImport: No viewer controller")
                        return
                    }
                    do {
                        try viewerController.displayBundle(at: bundleURL)
                        debugLog("performBAMImport: Bundle reloaded with alignment track (\(readCount) reads)")
                    } catch {
                        debugLog("performBAMImport: Bundle reload failed: \(error)")
                        self?.showAlert(title: "Import Error", message: "Alignments imported but bundle reload failed: \(error.localizedDescription)")
                    }

                case .failure(let error):
                    if cancelFlag.withLock({ $0 }) {
                        debugLog("performBAMImport: Cancelled by user")
                        // cancel() already called fail() via onCancel callback
                    } else {
                        OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
                        debugLog("performBAMImport: Failed: \(error)")
                        self?.showAlert(title: "BAM Import Failed", message: error.localizedDescription)
                    }
                }
            }
        }
    }

    @objc func exportFASTA(_ sender: Any?) {
        exportSequences(defaultFormat: .fasta)
    }

    @objc func exportGenBank(_ sender: Any?) {
        exportSequences(defaultFormat: .genbank)
    }

    /// Unified sequence export supporting multi-selection, format choice, and compression.
    private func exportSequences(defaultFormat: SequenceExportFormat) {
        // Try sidebar multi-selection first
        let sidebarItems = mainWindowController?.mainSplitViewController?.sidebarController?.selectedItems()
            .filter { $0.type == .referenceBundle || $0.type == .sequence } ?? []

        // Fall back to current document
        let documents: [LoadedDocument]
        if !sidebarItems.isEmpty {
            // Will load from sidebar items
            documents = []
        } else if let doc = mainWindowController?.mainSplitViewController?.viewerController?.currentDocument,
                  !doc.sequences.isEmpty {
            documents = [doc]
        } else {
            showExportError(message: "No sequences to export. Select files in the sidebar or open a document.")
            return
        }

        guard let window = mainWindowController?.window else { return }

        // Build save panel with format accessory
        let panel = NSSavePanel()
        panel.title = "Export Sequences"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true

        // Accessory view for format + compression
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 60))

        let formatLabel = NSTextField(labelWithString: "Format:")
        formatLabel.font = .systemFont(ofSize: 11)
        formatLabel.frame = NSRect(x: 0, y: 32, width: 60, height: 18)
        accessory.addSubview(formatLabel)

        let formatPopup = NSPopUpButton(frame: NSRect(x: 64, y: 28, width: 120, height: 24))
        formatPopup.controlSize = .small
        formatPopup.addItems(withTitles: ["FASTA", "GenBank"])
        formatPopup.selectItem(at: defaultFormat == .genbank ? 1 : 0)
        formatPopup.tag = 1
        accessory.addSubview(formatPopup)

        let compLabel = NSTextField(labelWithString: "Compression:")
        compLabel.font = .systemFont(ofSize: 11)
        compLabel.frame = NSRect(x: 0, y: 4, width: 80, height: 18)
        accessory.addSubview(compLabel)

        let compPopup = NSPopUpButton(frame: NSRect(x: 84, y: 0, width: 120, height: 24))
        compPopup.controlSize = .small
        compPopup.addItems(withTitles: ["None", "gzip (.gz)", "zstd (.zst)"])
        compPopup.tag = 2
        accessory.addSubview(compPopup)

        // Wire popup changes to update the suggested filename
        let baseName: String
        if sidebarItems.count == 1 {
            baseName = sidebarItems[0].title
        } else if sidebarItems.count > 1 {
            baseName = "exported_sequences"
        } else {
            baseName = documents[0].name.replacingOccurrences(of: ".\(documents[0].url.pathExtension)", with: "")
        }

        let filenameUpdater = ExportFilenameUpdater(panel: panel, baseName: baseName, formatPopup: formatPopup, compPopup: compPopup)
        formatPopup.target = filenameUpdater
        formatPopup.action = #selector(ExportFilenameUpdater.popupChanged(_:))
        compPopup.target = filenameUpdater
        compPopup.action = #selector(ExportFilenameUpdater.popupChanged(_:))
        objc_setAssociatedObject(panel, &ExportFilenameUpdater.associatedKey, filenameUpdater, .OBJC_ASSOCIATION_RETAIN)

        panel.accessoryView = accessory
        filenameUpdater.popupChanged(formatPopup) // set initial filename

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let outputURL = panel.url else { return }
            guard let self else { return }

            let format: SequenceExportFormat = formatPopup.indexOfSelectedItem == 1 ? .genbank : .fasta
            let compression: SequenceExportCompression
            switch compPopup.indexOfSelectedItem {
            case 1: compression = .gzip
            case 2: compression = .zstd
            default: compression = .none
            }

            let itemURLs = sidebarItems.compactMap(\.url)

            Task.detached { [weak self] in
                do {
                    let count = try await self?.performSequenceExport(
                        sidebarURLs: itemURLs,
                        documents: documents,
                        outputURL: outputURL,
                        format: format,
                        compression: compression
                    ) ?? 0

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let alert = NSAlert()
                            alert.messageText = "Export Complete"
                            alert.informativeText = "Exported \(count) sequence(s) to \(outputURL.lastPathComponent)."
                            alert.alertStyle = .informational
                            alert.addButton(withTitle: "OK")
                            alert.addButton(withTitle: "Show in Finder")
                            alert.beginSheetModal(for: window) { response in
                                if response == .alertSecondButtonReturn {
                                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                                }
                            }
                        }
                    }
                } catch {
                    debugLog("exportSequences: Failed - \(error)")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            let alert = NSAlert()
                            alert.messageText = "Export Failed"
                            alert.informativeText = error.localizedDescription
                            alert.alertStyle = .critical
                            alert.addButton(withTitle: "OK")
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    /// Loads sequences from sidebar URLs or documents, writes to output file, and optionally compresses.
    private func performSequenceExport(
        sidebarURLs: [URL],
        documents: [LoadedDocument],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        // Collect all sequences and annotations
        var allSequences: [LungfishCore.Sequence] = []
        var allAnnotations: [SequenceAnnotation] = []

        if !sidebarURLs.isEmpty {
            for url in sidebarURLs {
                let (seqs, annots) = try await loadSequencesForExport(from: url)
                allSequences.append(contentsOf: seqs)
                allAnnotations.append(contentsOf: annots)
            }
        } else {
            for doc in documents {
                allSequences.append(contentsOf: doc.sequences)
                allAnnotations.append(contentsOf: doc.annotations)
            }
        }

        guard !allSequences.isEmpty else {
            throw NSError(domain: "com.lungfish.browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No sequences found in selected files."])
        }

        // Determine write target (temp file if compressing, final file if not)
        let writeURL: URL
        if compression != .none {
            writeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("export-\(UUID().uuidString).\(format == .genbank ? "gb" : "fa")")
        } else {
            writeURL = outputURL
        }

        // Write the file
        switch format {
        case .fasta:
            let writer = FASTAWriter(url: writeURL)
            try writer.write(allSequences)

        case .genbank:
            var records: [GenBankRecord] = []
            for sequence in allSequences {
                let seqAnnotations = allAnnotations.filter {
                    $0.chromosome == nil || $0.chromosome == sequence.name
                }
                let moleculeType: MoleculeType
                switch sequence.alphabet {
                case .dna: moleculeType = .dna
                case .rna: moleculeType = .rna
                case .protein: moleculeType = .protein
                }
                let locus = LocusInfo(
                    name: sequence.name,
                    length: sequence.length,
                    moleculeType: moleculeType,
                    topology: .linear,
                    division: nil,
                    date: Self.currentDateString()
                )
                records.append(GenBankRecord(
                    sequence: sequence,
                    annotations: seqAnnotations,
                    locus: locus,
                    definition: sequence.description,
                    accession: nil,
                    version: nil
                ))
            }
            let writer = GenBankWriter(url: writeURL)
            try writer.write(records)
        }

        // Apply compression if needed
        if compression != .none {
            defer { try? FileManager.default.removeItem(at: writeURL) }
            switch compression {
            case .gzip:
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
                process.arguments = ["-c", writeURL.path]
                let outputHandle = try FileHandle(forWritingTo: {
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                    return outputURL
                }())
                process.standardOutput = outputHandle
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try outputHandle.close()
            case .zstd:
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zstd")
                process.arguments = ["-c", writeURL.path]
                let outputHandle = try FileHandle(forWritingTo: {
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                    return outputURL
                }())
                process.standardOutput = outputHandle
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                try outputHandle.close()
            case .none:
                break
            }
        }

        return allSequences.count
    }

    /// Reads sequences and annotations from a file or reference bundle for export.
    ///
    /// For reference bundles, reads the FASTA directly and loads annotations from the
    /// annotation database (BigBed tracks) via the bundle's data provider.
    /// For GenBank files, reads both sequences and annotations from the file.
    /// For FASTA files, reads sequences only.
    private func loadSequencesForExport(from url: URL) async throws -> ([LungfishCore.Sequence], [SequenceAnnotation]) {
        // Check if this document is already loaded in DocumentManager
        if let existingDoc = DocumentManager.shared.documents.first(where: {
            $0.url.standardizedFileURL == url.standardizedFileURL
        }), !existingDoc.sequences.isEmpty {
            return (existingDoc.sequences, existingDoc.annotations)
        }

        // Reference bundle: read FASTA path from manifest
        if url.pathExtension.lowercased() == "lungfishref" {
            let manifest = try BundleManifest.load(from: url)
            guard let genomePath = manifest.genome?.path else {
                throw NSError(domain: "com.lungfish.browser", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "No genome sequence in bundle \(url.lastPathComponent)"])
            }
            let sourceURL = url.appendingPathComponent(genomePath)
            // Decompress to temp file if needed (FASTAReader doesn't handle gzip internally)
            let readURL: URL
            var tempDecompressed: URL?
            if sourceURL.pathExtension.lowercased() == "gz" {
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("export-decomp-\(UUID().uuidString).fa")
                let gzStream = try GzipInputStream(url: sourceURL)
                let content = try await gzStream.readAll()
                try content.write(to: tmpURL, atomically: true, encoding: .utf8)
                readURL = tmpURL
                tempDecompressed = tmpURL
            } else {
                readURL = sourceURL
            }
            defer { if let tmp = tempDecompressed { try? FileManager.default.removeItem(at: tmp) } }

            let reader = try FASTAReader(url: readURL)
            let sequences = try await reader.readAll()

            // Load annotations from annotation tracks in the bundle
            var annotations: [SequenceAnnotation] = []
            for track in manifest.annotations {
                // Prefer SQLite database (has rich metadata) over BigBed
                if let dbPath = track.databasePath {
                    let dbURL = url.appendingPathComponent(dbPath)
                    if FileManager.default.fileExists(atPath: dbURL.path) {
                        let db = try AnnotationDatabase(url: dbURL)
                        let records = db.query(limit: Int.max)
                        annotations.append(contentsOf: records.map { $0.toAnnotation() })
                        continue
                    }
                }
            }
            return (sequences, annotations)
        }

        // GenBank file: read sequences and annotations
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" { checkURL = checkURL.deletingPathExtension() }
        let ext = checkURL.pathExtension.lowercased()
        if ext == "gb" || ext == "gbk" || ext == "genbank" || ext == "gbff" {
            let reader = try GenBankReader(url: url)
            let records = try await reader.readAll()
            var sequences: [LungfishCore.Sequence] = []
            var annotations: [SequenceAnnotation] = []
            for record in records {
                sequences.append(record.sequence)
                annotations.append(contentsOf: record.annotations)
            }
            return (sequences, annotations)
        }

        // FASTA file
        let reader = try FASTAReader(url: url)
        let sequences = try await reader.readAll()
        return (sequences, [])
    }

    private enum SequenceExportFormat {
        case fasta, genbank
    }

    private enum SequenceExportCompression {
        case none, gzip, zstd
    }

    /// Returns current date in GenBank format (DD-MMM-YYYY)
    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MMM-yyyy"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date()).uppercased()
    }

    @objc func exportGFF3(_ sender: Any?) {
        // Get current document
        guard let document = mainWindowController?.mainSplitViewController?.viewerController?.currentDocument else {
            showExportError(message: "No document is currently open.")
            return
        }

        // Check if there are annotations to export
        guard !document.annotations.isEmpty else {
            showExportError(message: "The current document has no annotations to export.")
            return
        }

        // Show save panel
        let panel = NSSavePanel()
        panel.title = "Export GFF3"
        panel.allowedContentTypes = [UTType(filenameExtension: "gff3")!]
        panel.nameFieldStringValue = document.name.replacingOccurrences(of: ".\(document.url.pathExtension)", with: "") + ".gff3"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            Task {
                do {
                    try await GFF3Writer.write(document.annotations, to: url, source: "Lungfish")

                    await MainActor.run {
                        debugLog("exportGFF3: Successfully exported \(document.annotations.count) annotations to \(url.path)")
                        self?.showExportSuccess(filename: url.lastPathComponent, count: document.annotations.count, itemType: "annotation")
                    }
                } catch {
                    await MainActor.run {
                        debugLog("exportGFF3: Export failed - \(error.localizedDescription)")
                        self?.showExportError(message: "Failed to export GFF3: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc func exportImage(_ sender: Any?) {
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            showExportError(message: "No viewer is currently available for export.")
            return
        }

        presentViewerGraphicsExportPanel(
            viewerController: viewerController,
            defaultFormat: .png,
            includeBitmapFormats: true
        )
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            showExportError(message: "No viewer is currently available for export.")
            return
        }

        presentViewerGraphicsExportPanel(
            viewerController: viewerController,
            defaultFormat: .pdf,
            includeBitmapFormats: false
        )
    }

    private enum ViewerExportScope: String, CaseIterable {
        case tracks = "tracks"
        case fullViewer = "full"
        case selectedRegion = "selection"

        var title: String {
            switch self {
            case .tracks: return "Tracks View (Sequence + Variants + Annotations)"
            case .fullViewer: return "Full Viewer Pane (Ruler + Tracks + Table)"
            case .selectedRegion: return "Selected Region Only"
            }
        }
    }

    private enum ViewerGraphicFormat: String, CaseIterable {
        case png
        case jpeg
        case tiff
        case pdf

        var title: String { rawValue.uppercased() }

        var contentType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            case .pdf: return .pdf
            }
        }

        var fileExtension: String { rawValue }

        var isVector: Bool { self == .pdf }
    }

    private func presentViewerGraphicsExportPanel(
        viewerController: ViewerViewController,
        defaultFormat: ViewerGraphicFormat,
        includeBitmapFormats: Bool
    ) {
        guard let window = mainWindowController?.window else {
            showExportError(message: "Unable to determine active window for export.")
            return
        }

        let hasSelection = viewerController.viewerView.selectionRange?.isEmpty == false
        let formats: [ViewerGraphicFormat] = includeBitmapFormats ? [.png, .jpeg, .tiff, .pdf] : [.pdf]
        let scopes: [ViewerExportScope] = hasSelection ? [.tracks, .fullViewer, .selectedRegion] : [.tracks, .fullViewer]
        let initialFormat = formats.contains(defaultFormat) ? defaultFormat : (formats.first ?? .png)

        let panel = NSSavePanel()
        panel.title = "Export Viewer Graphics"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = formats.map(\.contentType)
        panel.nameFieldStringValue = "viewer-export.\(initialFormat.fileExtension)"

        let scopeLabel = NSTextField(labelWithString: "Scope:")
        let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scopes.forEach { scopePopup.addItem(withTitle: $0.title) }
        if let idx = scopes.firstIndex(of: .tracks) { scopePopup.selectItem(at: idx) }

        let formatLabel = NSTextField(labelWithString: "Format:")
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formats.forEach { formatPopup.addItem(withTitle: $0.title) }
        if let idx = formats.firstIndex(of: initialFormat) { formatPopup.selectItem(at: idx) }

        let scaleLabel = NSTextField(labelWithString: "Bitmap Scale:")
        let scalePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ["1x", "2x", "4x"].forEach { scalePopup.addItem(withTitle: $0) }
        scalePopup.selectItem(at: 1)
        scalePopup.isEnabled = !initialFormat.isVector

        let accessory = NSStackView(views: [scopeLabel, scopePopup, formatLabel, formatPopup, scaleLabel, scalePopup])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 6
        panel.accessoryView = accessory

        func selectedFormat() -> ViewerGraphicFormat {
            let idx = max(0, min(formats.count - 1, formatPopup.indexOfSelectedItem))
            return formats[idx]
        }

        scalePopup.isEnabled = !selectedFormat().isVector

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let rawURL = panel.url else { return }

            let scope = scopes[max(0, min(scopes.count - 1, scopePopup.indexOfSelectedItem))]
            let format = selectedFormat()
            let scale: CGFloat
            switch scalePopup.indexOfSelectedItem {
            case 2: scale = 4
            case 1: scale = 2
            default: scale = 1
            }

            let outputURL = rawURL.pathExtension.lowercased() == format.fileExtension
                ? rawURL
                : rawURL.deletingPathExtension().appendingPathExtension(format.fileExtension)

            do {
                let data = try self.viewerExportData(
                    viewerController: viewerController,
                    scope: scope,
                    format: format,
                    bitmapScale: scale
                )
                try data.write(to: outputURL, options: .atomic)
                self.showExportSuccess(filename: outputURL.lastPathComponent, count: 1, itemType: "graphic")
            } catch {
                self.showExportError(message: "Failed to export viewer graphics: \(error.localizedDescription)")
            }
        }
    }

    private func viewerExportData(
        viewerController: ViewerViewController,
        scope: ViewerExportScope,
        format: ViewerGraphicFormat,
        bitmapScale: CGFloat
    ) throws -> Data {
        let (view, rect) = try viewerExportViewAndRect(viewerController: viewerController, scope: scope)
        if format.isVector {
            return view.dataWithPDF(inside: rect)
        }

        let pdfData = view.dataWithPDF(inside: rect)
        guard let image = NSImage(data: pdfData) else {
            throw NSError(domain: "LungfishExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to render export image"])
        }

        let pixelsWide = max(1, Int((rect.width * bitmapScale).rounded(.up)))
        let pixelsHigh = max(1, Int((rect.height * bitmapScale).rounded(.up)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "LungfishExport", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate bitmap export buffer"])
        }

        rep.size = NSSize(width: rect.width, height: rect.height)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "LungfishExport", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create bitmap graphics context"])
        }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .sourceOver, fraction: 1)

        let nsType: NSBitmapImageRep.FileType
        switch format {
        case .png: nsType = .png
        case .jpeg: nsType = .jpeg
        case .tiff: nsType = .tiff
        case .pdf: nsType = .png
        }
        guard let data = rep.representation(using: nsType, properties: [:]) else {
            throw NSError(domain: "LungfishExport", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to encode bitmap export data"])
        }
        return data
    }

    private func viewerExportViewAndRect(
        viewerController: ViewerViewController,
        scope: ViewerExportScope
    ) throws -> (NSView, NSRect) {
        switch scope {
        case .tracks:
            return (viewerController.viewerView, viewerController.viewerView.bounds)
        case .fullViewer:
            return (viewerController.view, viewerController.view.bounds)
        case .selectedRegion:
            guard let frame = viewerController.referenceFrame,
                  let range = viewerController.viewerView.selectionRange,
                  !range.isEmpty else {
                throw NSError(
                    domain: "LungfishExport",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "No selected region is available for export."]
                )
            }

            let rawStartX = frame.screenPosition(for: Double(range.lowerBound))
            let rawEndX = frame.screenPosition(for: Double(range.upperBound))
            let minX = max(frame.leadingInset, min(rawStartX, rawEndX))
            let maxDataX = max(frame.leadingInset, viewerController.viewerView.bounds.width - frame.trailingInset)
            let maxX = min(maxDataX, max(rawStartX, rawEndX))
            let width = max(1, maxX - minX)
            let rect = NSRect(x: minX, y: 0, width: width, height: viewerController.viewerView.bounds.height)
            return (viewerController.viewerView, rect)
        }
    }

    /// Shows an error alert for export failures
    private func showExportError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    /// Shows a success alert after export
    private func showExportSuccess(filename: String, count: Int, itemType: String) {
        let alert = NSAlert()
        alert.messageText = "Export Successful"
        let plural = count == 1 ? itemType : "\(itemType)s"
        alert.informativeText = "Successfully exported \(count) \(plural) to \(filename)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - ViewMenuActions

    @objc func toggleSidebar(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.toggleSidebar()
    }

    @objc func toggleInspector(_ sender: Any?) {
        let senderType = sender.map { String(describing: type(of: $0)) } ?? "nil"
        debugLog("toggleInspector[AppDelegate]: sender=\(senderType)")
        mainWindowController?.mainSplitViewController?.toggleInspector(source: "AppDelegate.toggleInspector")
    }

    @objc func zoomIn(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.viewerController?.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.viewerController?.zoomOut()
    }

    @objc func zoomToFit(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.viewerController?.zoomToFit()
    }

    @objc func zoomReset(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.viewerController?.zoomReset()
    }

    @objc func toggleNucleotideMode(_ sender: Any?) {
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            return
        }

        // Toggle the RNA mode
        viewerController.isRNAMode.toggle()

        // Trigger redraw
        viewerController.viewerView.needsDisplay = true

        // Persist to bundle view state
        viewerController.scheduleViewStateSave()
    }

    @objc func resetViewSettingsToDefaults(_ sender: Any?) {
        guard let splitVC = mainWindowController?.mainSplitViewController else { return }

        // Delegate to the inspector's existing reset (which posts all needed notifications)
        splitVC.inspectorController.resetAllAppearanceSettings()
    }

    @objc func showAIAssistant(_ sender: Any?) {
        showOrToggleAIAssistant()
    }

    @objc private func handleShowAIAssistant(_ notification: Notification) {
        showOrToggleAIAssistant()
    }

    /// Shows the AI assistant in the Inspector panel (AI tab).
    private func showOrToggleAIAssistant() {
        guard AppSettings.shared.aiSearchEnabled else {
            let alert = NSAlert()
            alert.messageText = "AI Assistant Disabled"
            alert.informativeText = "Enable AI-powered search in Settings > AI Services to use the assistant."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        guard let splitViewController = mainWindowController?.mainSplitViewController else {
            return
        }

        let service = ensureAIAssistantService()
        splitViewController.inspectorController.setAIAssistantService(service)
        splitViewController.setInspectorVisible(true, animated: false, source: "AppDelegate.showAIAssistant")

        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "ai"]
        )
    }

    /// Lazily creates and wires AI tool/service objects.
    private func ensureAIAssistantService() -> AIAssistantService {
        if let existing = aiAssistantService {
            return existing
        }

        let toolRegistry: AIToolRegistry
        if let existingRegistry = aiToolRegistry {
            toolRegistry = existingRegistry
        } else {
            toolRegistry = AIToolRegistry()
            aiToolRegistry = toolRegistry
            connectToolRegistryToViewer(toolRegistry)
        }

        let service = AIAssistantService(toolRegistry: toolRegistry)
        aiAssistantService = service
        return service
    }

    /// Updates the AI tool registry's search index when a new bundle loads.
    @objc private func handleBundleDidLoadForAI(_ notification: Notification) {
        guard let toolRegistry = aiToolRegistry else { return }
        if let searchIndex = mainWindowController?.mainSplitViewController?.viewerController?.annotationSearchIndex {
            toolRegistry.setSearchIndex(searchIndex)
        }
    }

    /// Connects the AI tool registry to the current viewer state and search index.
    private func connectToolRegistryToViewer(_ toolRegistry: AIToolRegistry) {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController

        // Connect search index (for gene/variant search)
        if let searchIndex = viewerController?.annotationSearchIndex {
            toolRegistry.setSearchIndex(searchIndex)
        }

        // Connect navigation callback
        toolRegistry.navigateToRegion = { [weak self] chromosome, start, end in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController,
                  let provider = viewerController.currentBundleDataProvider else { return }

            // Look up chromosome length from the manifest
            if let chromInfo = provider.chromosomeInfo(named: chromosome) {
                viewerController.navigateToChromosomeAndPosition(
                    chromosome: chromosome,
                    chromosomeLength: Int(chromInfo.length),
                    start: start,
                    end: end
                )
            }
        }

        toolRegistry.getVariantTableContext = { [weak self] selectionScope, limit in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return "No active viewer is available."
            }
            guard let drawer = viewerController.annotationDrawerView else {
                return "Variant table is unavailable because the bottom drawer is not open."
            }

            let isVariantTabActive = drawer.activeTab == .variants
            let isCallsSubtabActive = drawer.activeVariantSubtab == .calls
            let selectedRows = drawer.aiVariantRows(
                limit: limit,
                selectedOnly: true,
                fallbackToVisibleIfSelectionEmpty: false
            )
            let visibleRows = drawer.aiVariantRows(
                limit: limit,
                selectedOnly: false,
                fallbackToVisibleIfSelectionEmpty: false
            )

            let rows: [AnnotationSearchIndex.SearchResult]
            switch selectionScope {
            case "selected":
                rows = selectedRows
            case "visible":
                rows = visibleRows
            default:
                rows = selectedRows.isEmpty ? visibleRows : selectedRows
            }

            var lines: [String] = []
            lines.append("Variant table state:")
            lines.append("  Variant tab active: \(isVariantTabActive ? "yes" : "no")")
            lines.append("  Calls subtab active: \(isCallsSubtabActive ? "yes" : "no")")
            lines.append("  Selected rows: \(selectedRows.count)")
            lines.append("  Visible rows: \(visibleRows.count)")

            if rows.isEmpty {
                lines.append("No rows available for selection_scope='\(selectionScope)'.")
                return lines.joined(separator: "\n")
            }

            lines.append("Rows returned (\(rows.count), scope=\(selectionScope)):")
            for row in rows {
                let qualityString = row.quality.map { String(format: "%.1f", $0) } ?? "."
                var infoParts: [String] = []
                if let info = row.infoDict {
                    for key in ["CSQ_SYMBOL", "SYMBOL", "CSQ_IMPACT", "IMPACT", "CSQ_Consequence", "Consequence", "AF"] {
                        if let value = info[key], !value.isEmpty {
                            infoParts.append("\(key)=\(value)")
                        }
                    }
                    if infoParts.isEmpty {
                        let keys = info.keys.sorted().prefix(4)
                        for key in keys {
                            if let value = info[key], !value.isEmpty {
                                infoParts.append("\(key)=\(value)")
                            }
                        }
                    }
                }

                let infoSummary = infoParts.isEmpty ? "" : " info{\(infoParts.joined(separator: "; "))}"
                let rowId = row.variantRowId.map(String.init) ?? "nil"
                lines.append(
                    "- id=\(row.name) chrom=\(row.chromosome) pos1=\(row.start + 1) ref=\(row.ref ?? ".") alt=\(row.alt ?? ".") type=\(row.type) qual=\(qualityString) filter=\(row.filter ?? ".") samples=\(row.sampleCount ?? 0) track=\(row.trackId) row_id=\(rowId)\(infoSummary)"
                )
            }

            return lines.joined(separator: "\n")
        }

        toolRegistry.getSampleTableContext = { [weak self] selectionScope, limit, visibleOnly in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return "No active viewer is available."
            }
            guard let drawer = viewerController.annotationDrawerView else {
                return "Sample table is unavailable because the bottom drawer is not open."
            }

            let isSampleTabActive = drawer.activeTab == .samples
            let selectedRows = drawer.aiSampleRows(
                limit: limit,
                selectedOnly: true,
                visibleOnly: visibleOnly,
                fallbackToVisibleIfSelectionEmpty: false
            )
            let visibleRows = drawer.aiSampleRows(
                limit: limit,
                selectedOnly: false,
                visibleOnly: visibleOnly,
                fallbackToVisibleIfSelectionEmpty: false
            )

            let rows: [AnnotationTableDrawerView.SampleDisplayRow]
            switch selectionScope {
            case "selected":
                rows = selectedRows
            case "visible":
                rows = visibleRows
            default:
                rows = selectedRows.isEmpty ? visibleRows : selectedRows
            }

            var lines: [String] = []
            lines.append("Sample table state:")
            lines.append("  Samples tab active: \(isSampleTabActive ? "yes" : "no")")
            lines.append("  Selected rows: \(selectedRows.count)")
            lines.append("  Visible rows: \(visibleRows.count)")
            lines.append("  visible_only: \(visibleOnly ? "true" : "false")")

            if rows.isEmpty {
                lines.append("No rows available for selection_scope='\(selectionScope)'.")
                return lines.joined(separator: "\n")
            }

            lines.append("Rows returned (\(rows.count), scope=\(selectionScope)):")
            for row in rows {
                let metadataPairs = row.metadata
                    .sorted { $0.key < $1.key }
                    .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .prefix(6)
                    .map { "\($0.key)=\($0.value)" }
                let metadataSummary = metadataPairs.isEmpty ? "" : " metadata{\(metadataPairs.joined(separator: "; "))}"
                lines.append("- sample=\(row.name) visible=\(row.isVisible ? "true" : "false") source=\(row.sourceFile)\(metadataSummary)")
            }

            return lines.joined(separator: "\n")
        }

        // Connect current view state callback
        toolRegistry.getCurrentViewState = { [weak self] in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return AIToolRegistry.ViewerState()
            }

            let provider = viewerController.currentBundleDataProvider
            let frame = viewerController.referenceFrame

            // Count variant tracks
            let variantHandles = viewerController.annotationSearchIndex?.variantDatabaseHandles ?? []
            let variantTrackCount = variantHandles.count
            let totalVariantCount = variantHandles.reduce(0) { $0 + $1.db.totalCount() }

            var sampleCount = 0
            var allSampleNames: [String] = []
            var sampleNameExamples: [String] = []
            for handle in variantHandles {
                let count = handle.db.sampleCount()
                if count > sampleCount {
                    sampleCount = count
                    allSampleNames = handle.db.sampleNames()
                    sampleNameExamples = Array(allSampleNames.prefix(4))
                }
            }

            // Visible sample subset from current sample display state (visualizer-driven).
            let hiddenSamples = viewerController.viewerView.sampleDisplayState.hiddenSamples
            let visibleSampleNames = allSampleNames.filter { !hiddenSamples.contains($0) }
            let visibleSampleCount = visibleSampleNames.count
            let visibleSampleExamples = Array(visibleSampleNames.prefix(6))

            // Table-visible rows from the annotation drawer (when initialized/opened).
            let drawer = viewerController.annotationDrawerView
            let displayedVariantRows = (drawer?.activeTab == .variants)
                ? (drawer?.displayedAnnotations ?? [])
                : []
            let variantTableExamples = displayedVariantRows.prefix(6).map { row in
                "\(row.name) \(row.chromosome):\(row.start + 1)-\(row.end) [\(row.type)]"
            }

            let displayedSampleRows = drawer?.displayedSamples ?? []
            let sampleTableRows = displayedSampleRows.isEmpty
                ? allSampleNames.map { name in !hiddenSamples.contains(name) ? name : nil }.compactMap { $0 }
                : displayedSampleRows.filter(\.isVisible).map(\.name)
            let sampleTableExamples = Array(sampleTableRows.prefix(6))

            return AIToolRegistry.ViewerState(
                chromosome: frame?.chromosome,
                start: frame.map { Int($0.start) },
                end: frame.map { Int($0.end) },
                organism: provider?.organism,
                assembly: provider?.assembly,
                bundleName: provider?.name,
                chromosomeNames: provider?.chromosomes.map(\.name) ?? [],
                annotationTrackCount: provider?.annotationTrackIds.count ?? 0,
                variantTrackCount: variantTrackCount,
                totalVariantCount: totalVariantCount,
                sampleCount: sampleCount,
                sampleNameExamples: sampleNameExamples,
                visibleSampleCount: visibleSampleCount,
                visibleSampleExamples: visibleSampleExamples,
                variantTableRowCount: displayedVariantRows.count,
                variantTableExamples: variantTableExamples,
                sampleTableRowCount: sampleTableRows.count,
                sampleTableExamples: sampleTableExamples
            )
        }
    }

    // MARK: - Menu Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Update Sidebar menu item title based on state (Apple HIG compliance)
        // Tag 1000 is for sidebar toggle
        if menuItem.tag == 1000 {
            if let isSidebarVisible = mainWindowController?.mainSplitViewController?.isSidebarVisible {
                menuItem.title = isSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
            }
            return true
        }

        // Update Inspector menu item title based on state
        if menuItem.tag == 1001 {
            if let isInspectorVisible = mainWindowController?.mainSplitViewController?.isInspectorVisible {
                menuItem.title = isInspectorVisible ? "Hide Inspector" : "Show Inspector"
            }
            return true
        }

        // Update DNA/RNA mode menu item state
        if menuItem.tag == 1002 {
            if let isRNAMode = mainWindowController?.mainSplitViewController?.viewerController?.isRNAMode {
                menuItem.state = isRNAMode ? .on : .off
            }
            return true
        }

        // "Import VCF Variants..." is always enabled (auto-ingest creates bundle if needed)
        if menuItem.action == #selector(importVCFToBundle(_:)) {
            return true
        }

        // "Import BAM/CRAM Alignments..." and sample metadata require a loaded bundle
        if menuItem.action == #selector(importBAMToBundle(_:))
            || menuItem.action == #selector(importSampleMetadataToBundle(_:)) {
            let hasBundle = mainWindowController?.mainSplitViewController?.viewerController?.currentBundleURL != nil
            return hasBundle
        }

        // Copy visible region requires an active viewer.
        if menuItem.action == #selector(copySelectionFASTA(_:)) {
            return mainWindowController?.mainSplitViewController?.viewerController?.viewerView != nil
        }

        // Extract can bootstrap from the currently visible region.
        if menuItem.action == #selector(extractSelection(_:)) {
            let hasViewer = mainWindowController?.mainSplitViewController?.viewerController?.viewerView != nil
            return hasViewer
        }

        // "Cancel All Operations" needs running operations
        if menuItem.action == #selector(cancelAllOperations(_:)) {
            return OperationCenter.shared.activeCount > 0
        }

        // "Clear Completed" needs finished items
        if menuItem.action == #selector(clearCompletedOperations(_:)) {
            return OperationCenter.shared.items.contains { $0.state != .running }
        }

        return true
    }

    // MARK: - SequenceMenuActions

    @objc func reverseComplement(_ sender: Any?) {
        guard let viewerView = mainWindowController?.mainSplitViewController?.viewerController?.viewerView else {
            showAlert(title: "No Viewer", message: "Open a sequence to use Reverse Complement.")
            return
        }
        // Delegate to the viewer view's reverse complement copy action
        viewerView.performReverseComplement()
    }

    @objc func translate(_ sender: Any?) {
        mainWindowController?.showTranslationTool(sender)
    }


    @objc func goToPosition(_ sender: Any?) {
        // Ensure we have a viewer controller
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            showAlert(title: "No Viewer", message: "No sequence viewer is available.")
            return
        }

        // Ensure a sequence is loaded
        guard viewerController.referenceFrame != nil else {
            showAlert(title: "No Sequence", message: "Please load a sequence before navigating to a position.")
            return
        }

        // Show go-to-position dialog
        let alert = NSAlert()
        alert.messageText = "Go to Position"
        alert.informativeText = "Enter a genomic position or region.\n\nSupported formats:\n  1000 (position)\n  chr1:1000 (chromosome:position)\n  chr1:1000-2000 (range with hyphen)\n  chr1:1000..2000 (range with dots)"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.placeholderString = "e.g., 1000 or chr1:1000-2000"
        alert.accessoryView = textField

        // Make the text field first responder
        alert.window.initialFirstResponder = textField

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                let input = textField.stringValue.trimmingCharacters(in: .whitespaces)

                guard !input.isEmpty else {
                    showAlert(title: "Invalid Input", message: "Please enter a position or range.")
                    return
                }

                // Parse the input and navigate
                let result = parseAndNavigate(input: input, viewerController: viewerController)
                if !result.success {
                    showAlert(title: "Navigation Error", message: result.errorMessage ?? "Failed to navigate to the specified position.")
                }
            }
        }
    }

    /// Parses genomic position input and navigates the viewer.
    ///
    /// Supported formats:
    /// - "1000" - single position
    /// - "chr1:1000" - chromosome:position
    /// - "chr1:1000-2000" or "chr1:1000..2000" - range
    ///
    /// - Parameters:
    ///   - input: The user-provided position string
    ///   - viewerController: The viewer controller to navigate
    /// - Returns: A tuple with success status and optional error message
    private func parseAndNavigate(input: String, viewerController: ViewerViewController) -> (success: Bool, errorMessage: String?) {
        var chromosome: String? = nil
        var startPosition: Int? = nil
        var endPosition: Int? = nil

        // Check if input contains a chromosome prefix (contains ":")
        if input.contains(":") {
            // Format: chromosome:position or chromosome:start-end
            let colonParts = input.split(separator: ":", maxSplits: 1)
            guard colonParts.count == 2 else {
                return (false, "Invalid format. Expected 'chromosome:position' or 'chromosome:start-end'.")
            }

            chromosome = String(colonParts[0])
            let positionPart = String(colonParts[1])

            // Check for range separator (either "-" or "..")
            if positionPart.contains("..") {
                // Format: start..end
                let rangeParts = positionPart.split(separator: ".", omittingEmptySubsequences: true)
                guard rangeParts.count == 2,
                      let start = Int(rangeParts[0].trimmingCharacters(in: .whitespaces)),
                      let end = Int(rangeParts[1].trimmingCharacters(in: .whitespaces)) else {
                    return (false, "Invalid range format. Expected 'start..end' with numeric values.")
                }
                startPosition = start
                endPosition = end
            } else if positionPart.contains("-") {
                // Format: start-end (but need to handle negative numbers)
                // Find the last hyphen that's preceded by a digit (to distinguish range separator from negative sign)
                if let rangeHyphenIndex = positionPart.lastIndex(of: "-"),
                   rangeHyphenIndex > positionPart.startIndex {
                    let beforeHyphen = String(positionPart[positionPart.startIndex..<rangeHyphenIndex])
                    let afterHyphen = String(positionPart[positionPart.index(after: rangeHyphenIndex)...])

                    if let start = Int(beforeHyphen.trimmingCharacters(in: .whitespaces)),
                       let end = Int(afterHyphen.trimmingCharacters(in: .whitespaces)) {
                        startPosition = start
                        endPosition = end
                    } else {
                        // Try parsing the whole thing as a single position
                        if let pos = Int(positionPart.trimmingCharacters(in: .whitespaces)) {
                            startPosition = pos
                        } else {
                            return (false, "Invalid position format. Expected numeric value.")
                        }
                    }
                } else {
                    // Single position
                    if let pos = Int(positionPart.trimmingCharacters(in: .whitespaces)) {
                        startPosition = pos
                    } else {
                        return (false, "Invalid position format. Expected numeric value.")
                    }
                }
            } else {
                // Single position
                if let pos = Int(positionPart.trimmingCharacters(in: .whitespaces)) {
                    startPosition = pos
                } else {
                    return (false, "Invalid position format. Expected numeric value.")
                }
            }
        } else {
            // No chromosome prefix - just a position or range
            if input.contains("..") {
                // Range with ".."
                let rangeParts = input.split(separator: ".", omittingEmptySubsequences: true)
                guard rangeParts.count == 2,
                      let start = Int(String(rangeParts[0]).trimmingCharacters(in: .whitespaces)),
                      let end = Int(String(rangeParts[1]).trimmingCharacters(in: .whitespaces)) else {
                    return (false, "Invalid range format. Expected 'start..end' with numeric values.")
                }
                startPosition = start
                endPosition = end
            } else if input.contains("-") && input.first != "-" {
                // Range with "-" (not starting with negative sign)
                let rangeParts = input.split(separator: "-")
                if rangeParts.count == 2,
                   let start = Int(String(rangeParts[0]).trimmingCharacters(in: .whitespaces)),
                   let end = Int(String(rangeParts[1]).trimmingCharacters(in: .whitespaces)) {
                    startPosition = start
                    endPosition = end
                } else if let pos = Int(input.trimmingCharacters(in: .whitespaces)) {
                    startPosition = pos
                } else {
                    return (false, "Invalid format. Expected position number or 'start-end' range.")
                }
            } else {
                // Simple position number
                if let pos = Int(input.trimmingCharacters(in: .whitespaces)) {
                    startPosition = pos
                } else {
                    return (false, "Invalid position. Please enter a numeric value.")
                }
            }
        }

        // Validate we have at least a start position
        guard let start = startPosition else {
            return (false, "Could not parse the position value.")
        }

        // Convert from 1-based user input to 0-based internal coordinates
        // Users typically think in 1-based coordinates for genomic positions
        let zeroBasedStart = max(0, start - 1)
        let zeroBasedEnd: Int? = endPosition.map { max(zeroBasedStart + 1, $0) }

        // Navigate using the helper method
        let success = viewerController.navigateToPosition(
            chromosome: chromosome,
            start: zeroBasedStart,
            end: zeroBasedEnd
        )

        if success {
            debugLog("goToPosition: Navigated to \(chromosome ?? "current"):\(zeroBasedStart)-\(zeroBasedEnd ?? zeroBasedStart)")
            return (true, nil)
        } else {
            return (false, "Position is outside the sequence bounds.")
        }
    }

    @objc func copySelectionFASTA(_ sender: Any?) {
        guard let viewerView = mainWindowController?.mainSplitViewController?.viewerController?.viewerView else {
            NSSound.beep()
            return
        }
        viewerView.copySelectionAsFASTA(sender)
    }

    @objc func extractSelection(_ sender: Any?) {
        guard let viewerView = mainWindowController?.mainSplitViewController?.viewerController?.viewerView else {
            NSSound.beep()
            return
        }
        viewerView.extractSelectionSequence(sender)
    }

    @objc func addAnnotation(_ sender: Any?) {
        // Get the current selection from the viewer
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController else {
            showAlert(title: "No Viewer", message: "No sequence viewer available.")
            return
        }

        // Access the viewer view to get selection range
        guard let selectionRange = viewerController.viewerView?.selectionRange else {
            showAlert(title: "No Selection", message: "Please select a region of the sequence first.")
            return
        }

        // Show the annotation dialog
        let alert = NSAlert()
        alert.messageText = "Add Annotation"
        alert.informativeText = "Add an annotation for the selected region (\(selectionRange.lowerBound + 1)-\(selectionRange.upperBound))"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        // Create accessory view with form fields
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 120))

        // Name field
        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 0, y: 90, width: 60, height: 20)
        accessoryView.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 70, y: 88, width: 220, height: 24))
        nameField.placeholderString = "Annotation name"
        accessoryView.addSubview(nameField)

        // Type popup
        let typeLabel = NSTextField(labelWithString: "Type:")
        typeLabel.frame = NSRect(x: 0, y: 55, width: 60, height: 20)
        accessoryView.addSubview(typeLabel)

        let typePopup = NSPopUpButton(frame: NSRect(x: 70, y: 53, width: 220, height: 24))
        typePopup.addItems(withTitles: [
            "gene", "CDS", "exon", "mRNA", "region", "misc_feature",
            "promoter", "primer", "restriction_site"
        ])
        accessoryView.addSubview(typePopup)

        // Strand popup
        let strandLabel = NSTextField(labelWithString: "Strand:")
        strandLabel.frame = NSRect(x: 0, y: 20, width: 60, height: 20)
        accessoryView.addSubview(strandLabel)

        let strandPopup = NSPopUpButton(frame: NSRect(x: 70, y: 18, width: 100, height: 24))
        strandPopup.addItems(withTitles: ["+", "-", "none"])
        accessoryView.addSubview(strandPopup)

        alert.accessoryView = accessoryView

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                let name = nameField.stringValue.isEmpty ? "New Annotation" : nameField.stringValue
                let typeString = typePopup.selectedItem?.title ?? "region"
                let strandString = strandPopup.selectedItem?.title ?? "none"

                // Create the annotation
                let annotationType = AnnotationType(rawValue: typeString) ?? .region
                let strand: Strand = strandString == "+" ? .forward : (strandString == "-" ? .reverse : .unknown)

                let annotation = SequenceAnnotation(
                    type: annotationType,
                    name: name,
                    intervals: [AnnotationInterval(start: selectionRange.lowerBound, end: selectionRange.upperBound)],
                    strand: strand
                )

                // Add to the current document
                if let document = DocumentManager.shared.activeDocument {
                    document.annotations.append(annotation)

                    // Refresh the viewer to show the new annotation
                    viewerController.displayDocument(document)

                    debugLog("Added annotation: \(name) (\(typeString)) at \(selectionRange)")
                }
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    @objc func findORFs(_ sender: Any?) {
        showNotImplementedAlert("ORF Finder")
    }

    @objc func findRestrictionSites(_ sender: Any?) {
        showNotImplementedAlert("Restriction Site Finder")
    }

    // MARK: - ToolsMenuActions


    @objc func runSPAdes(_ sender: Any?) {
        guard let window = mainWindowController?.window else {
            debugLog("runSPAdes: No main window available")
            return
        }

        // Get selected FASTQ files from sidebar
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController
        let selectedItems = sidebarController?.selectedItems() ?? []
        let inputFiles = selectedItems.compactMap { item -> URL? in
            guard let url = item.url else { return nil }
            return FASTQBundle.resolvePrimaryFASTQURL(for: url)
        }

        if inputFiles.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "No FASTQ Files Selected"
            alert.informativeText = "Select one or more FASTQ files or FASTQ bundles in the sidebar, then choose Assemble with SPAdes."
            alert.addButton(withTitle: "OK")
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        // Output goes to Assemblies/ subfolder in the project directory
        let outputDirectory: URL?
        if let projectURL = sidebarController?.currentProjectURL {
            outputDirectory = projectURL.appendingPathComponent("Assemblies", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            outputDirectory = workingURL.appendingPathComponent("Assemblies", isDirectory: true)
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            outputDirectory = documentsURL.appendingPathComponent("Lungfish-Assemblies", isDirectory: true)
        }

        debugLog("runSPAdes: \(inputFiles.count) files, output=\(outputDirectory?.path ?? "nil")")

        AssemblySheetPresenter.present(
            from: window,
            inputFiles: inputFiles,
            outputDirectory: outputDirectory,
            onCancel: {
                debugLog("Assembly configuration cancelled")
            }
        )
    }

    @objc func designPrimers(_ sender: Any?) {
        showNotImplementedAlert("Primer Design")
    }

    @objc func primalScheme(_ sender: Any?) {
        showNotImplementedAlert("PrimalScheme")
    }

    @objc func inSilicoPCR(_ sender: Any?) {
        showNotImplementedAlert("In-Silico PCR")
    }

    @objc func alignSequences(_ sender: Any?) {
        showNotImplementedAlert("Sequence Alignment")
    }

    @objc func searchNCBI(_ sender: Any?) {
        showDatabaseBrowser(source: .ncbi)
    }

    @objc func searchSRA(_ sender: Any?) {
        // Use ENA service for SRA/FASTQ retrieval
        showDatabaseBrowser(source: .ena)
    }

    @objc func searchPathoplexus(_ sender: Any?) {
        showDatabaseBrowser(source: .pathoplexus)
    }

    /// Shows the database browser for the specified source.
    private func showDatabaseBrowser(source: DatabaseSource) {
        guard let window = mainWindowController?.window else { return }

        let browserController = DatabaseBrowserViewController(source: source)

        // Dismiss the sheet immediately when a download is kicked off.
        // The download continues in background via DownloadCenter. Bundle
        // import is handled by DownloadCenter.onBundleReady (set in
        // applicationDidFinishLaunching), eliminating the fragile callback
        // chain through the sheet controller.
        browserController.onDownloadStarted = {
            debugLog("onDownloadStarted: Dismissing sheet immediately")
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }

        // Present as sheet
        let browserWindow = NSWindow(contentViewController: browserController)
        let title: String
        switch source {
        case .ncbi:
            title = "Search NCBI"
        case .ena:
            title = "Search SRA"
        case .pathoplexus:
            title = "Search Pathoplexus"
        default:
            title = "Search \(source.displayName)"
        }
        browserWindow.title = title

        window.beginSheet(browserWindow) { _ in
            debugLog("Sheet dismissed callback executing")
        }
    }

    /// Temporary storage for download URL while sheet is dismissing
    private var pendingDownloadTempURL: URL?

    /// Temporary storage for multiple download URLs while sheet is dismissing
    private var pendingDownloadTempURLs: [URL]?

    /// Handles multiple downloaded files with better progress tracking.
    ///
    /// This method processes multiple downloaded files sequentially, showing overall progress
    /// in the activity indicator and refreshing the sidebar once at the end.
    ///
    /// - Parameter tempFileURLs: Array of URLs of downloaded files in the temp directory
    private func handleMultipleDownloadsSync(_ tempFileURLs: [URL]) {
        guard !tempFileURLs.isEmpty else { return }

        debugLog("handleMultipleDownloadsSync: Starting with \(tempFileURLs.count) files")

        // Get UI controllers
        let activityIndicator = mainWindowController?.mainSplitViewController?.activityIndicator
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        let totalCount = tempFileURLs.count
        activityIndicator?.show(message: "Importing \(totalCount) file\(totalCount == 1 ? "" : "s")...", style: .indeterminate)

        // Determine destination directory
        let destinationDirectory: URL
        if let projectURL = DocumentManager.shared.activeProject?.url {
            destinationDirectory = projectURL.appendingPathComponent("Downloads", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            destinationDirectory = workingURL.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Create destination directory
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("handleMultipleDownloadsSync: Failed to create directory - \(error)")
            activityIndicator?.hide()
            return
        }

        var copiedURLs: [URL] = []

        // Copy all files first
        for (index, tempURL) in tempFileURLs.enumerated() {
            // Skip copy if file is already inside the project directory (e.g. extraction bundles
            // saved directly to Extractions folder). Just use the URL as-is.
            let alreadyInProject: Bool
            if let projectURL = DocumentManager.shared.activeProject?.url,
               isURL(tempURL, inside: projectURL) {
                alreadyInProject = true
            } else if let workingURL = workingDirectoryURL,
                      isURL(tempURL, inside: workingURL) {
                alreadyInProject = true
            } else {
                alreadyInProject = false
            }

            if alreadyInProject {
                debugLog("handleMultipleDownloadsSync: \(tempURL.lastPathComponent) already in project, skipping copy")
                copiedURLs.append(tempURL)
                continue
            }

            let originalFilename = tempURL.lastPathComponent

            // Build the full compound extension (e.g. "fastq.gz") and true base name
            var strippedURL = tempURL
            var extensionParts: [String] = []
            while !strippedURL.pathExtension.isEmpty {
                extensionParts.insert(strippedURL.pathExtension, at: 0)
                strippedURL = strippedURL.deletingPathExtension()
            }
            let fileExtension = extensionParts.joined(separator: ".")
            var baseName = strippedURL.lastPathComponent

            // Strip the UID suffix from batch downloads (format: "accession_uid.ext" -> "accession.ext")
            // UIDs are numeric, so we look for _digits at the end of the basename.
            // Skip for .lungfishref bundles — their filenames are already clean accessions
            // and accession numbers like NC_045512 contain underscore+digits that would be
            // incorrectly stripped.
            if !extensionParts.contains("lungfishref"),
               !extensionParts.contains(FASTQBundle.directoryExtension),
               !FASTQBundle.isFASTQFileURL(tempURL),
               let underscoreRange = baseName.range(of: "_", options: .backwards) {
                let potentialUID = String(baseName[underscoreRange.upperBound...])
                // Check if everything after the underscore is digits (a UID)
                if !potentialUID.isEmpty && potentialUID.allSatisfy({ $0.isNumber }) {
                    baseName = String(baseName[..<underscoreRange.lowerBound])
                    debugLog("handleMultipleDownloadsSync: Stripped UID from filename, using base: \(baseName)")
                }
            }

            let cleanFilename = "\(baseName).\(fileExtension)"
            activityIndicator?.updateMessage("Copying \(cleanFilename) (\(index + 1)/\(totalCount))...")

            // FASTQ imports are stored as package bundles so the FASTQ payload,
            // index, and metadata always travel together.
            if FASTQBundle.isFASTQFileURL(tempURL) {
                var bundleURL = destinationDirectory.appendingPathComponent(
                    "\(baseName).\(FASTQBundle.directoryExtension)",
                    isDirectory: true
                )
                var bundleCounter = 1
                while FileManager.default.fileExists(atPath: bundleURL.path) {
                    bundleURL = destinationDirectory.appendingPathComponent(
                        "\(baseName)_\(bundleCounter).\(FASTQBundle.directoryExtension)",
                        isDirectory: true
                    )
                    bundleCounter += 1
                }

                do {
                    try FileManager.default.createDirectory(
                        at: bundleURL,
                        withIntermediateDirectories: true
                    )

                    let bundledFASTQURL = bundleURL.appendingPathComponent(cleanFilename)
                    try FileManager.default.copyItem(at: tempURL, to: bundledFASTQURL)
                    debugLog("handleMultipleDownloadsSync: Packaged \(originalFilename) into \(bundleURL.path)")

                    let sourceSidecar = FASTQMetadataStore.metadataURL(for: tempURL)
                    if FileManager.default.fileExists(atPath: sourceSidecar.path) {
                        let destSidecar = FASTQMetadataStore.metadataURL(for: bundledFASTQURL)
                        try? FileManager.default.copyItem(at: sourceSidecar, to: destSidecar)
                        try? FileManager.default.removeItem(at: sourceSidecar)
                    }

                    let sourceFASTQIndex = tempURL.appendingPathExtension("fai")
                    if FileManager.default.fileExists(atPath: sourceFASTQIndex.path) {
                        let destFASTQIndex = bundledFASTQURL.appendingPathExtension("fai")
                        try? FileManager.default.copyItem(at: sourceFASTQIndex, to: destFASTQIndex)
                        try? FileManager.default.removeItem(at: sourceFASTQIndex)
                    }

                    try? FileManager.default.removeItem(at: tempURL)
                    copiedURLs.append(bundleURL)
                } catch {
                    debugLog("handleMultipleDownloadsSync: Failed to package FASTQ \(originalFilename) - \(error)")
                }
                continue
            }

            // Generate unique filename if needed
            var destinationURL = destinationDirectory.appendingPathComponent(cleanFilename)
            var counter = 1

            while FileManager.default.fileExists(atPath: destinationURL.path) {
                let newFilename = "\(baseName)_\(counter).\(fileExtension)"
                destinationURL = destinationDirectory.appendingPathComponent(newFilename)
                counter += 1
            }

            // Copy file
            do {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
                debugLog("handleMultipleDownloadsSync: Copied \(originalFilename) to \(destinationURL.path)")

                // Copy metadata sidecar if it exists (e.g. SRA/ENA download metadata)
                let sidecarURL = FASTQMetadataStore.metadataURL(for: tempURL)
                if FileManager.default.fileExists(atPath: sidecarURL.path) {
                    let destSidecar = FASTQMetadataStore.metadataURL(for: destinationURL)
                    try? FileManager.default.copyItem(at: sidecarURL, to: destSidecar)
                    try? FileManager.default.removeItem(at: sidecarURL)
                }

                // Copy FASTQ index sidecar when present (e.g. pre-import fqidx output).
                let sourceFASTQIndex = tempURL.appendingPathExtension("fai")
                if FileManager.default.fileExists(atPath: sourceFASTQIndex.path) {
                    let destFASTQIndex = destinationURL.appendingPathExtension("fai")
                    try? FileManager.default.copyItem(at: sourceFASTQIndex, to: destFASTQIndex)
                    try? FileManager.default.removeItem(at: sourceFASTQIndex)
                }

                try? FileManager.default.removeItem(at: tempURL)
                copiedURLs.append(destinationURL)
            } catch {
                debugLog("handleMultipleDownloadsSync: Failed to copy \(originalFilename) - \(error)")
            }
        }

        // Trigger FASTQ ingestion for any imported FASTQ files (now at their final location)
        for url in copiedURLs {
            if let fastqURL = FASTQBundle.resolvePrimaryFASTQURL(for: url) {
                let existingMeta = FASTQMetadataStore.load(for: fastqURL)
                FASTQIngestionService.ingestIfNeeded(url: fastqURL, existingMetadata: existingMeta)
            }
        }

        // Now load the first file to display (load others in background)
        if let firstURL = copiedURLs.first {
            if firstURL.pathExtension.lowercased() == "lungfishref" ||
                FASTQBundle.resolvePrimaryFASTQURL(for: firstURL) != nil {
                activityIndicator?.hide()
                refreshSidebarAndSelectImportedURL(firstURL)
                debugLog("handleMultipleDownloadsSync: Imported \(copiedURLs.count) bundled item(s)")
                return
            }

            activityIndicator?.updateMessage("Loading \(firstURL.lastPathComponent)...")

            loadFileInBackground(at: firstURL) { result in
                scheduleOnMainRunLoop { [weak activityIndicator, weak viewerController, weak sidebarController] in
                    if result.error == nil {
                        // Create and display the first document
                        let document = LoadedDocument(url: result.url, type: result.type)
                        document.sequences = result.sequences
                        document.annotations = result.annotations
                        DocumentManager.shared.registerDocument(document)
                        viewerController?.displayDocument(document)
                        debugLog("handleMultipleDownloadsSync: Displayed first document '\(document.name)'")
                    }

                    activityIndicator?.hide()

                    // Refresh sidebar to show all new files
                    sidebarController?.reloadFromFilesystem()

                    // Select the first downloaded file in the sidebar to highlight what's being viewed
                    if result.error == nil {
                        sidebarController?.selectItem(forURL: result.url)
                        self.requestInspectorDocumentModeAfterDownload()
                    }

                    debugLog("handleMultipleDownloadsSync: Completed importing \(copiedURLs.count) files")
                }
            }
        } else {
            activityIndicator?.hide()
            sidebarController?.reloadFromFilesystem()
        }
    }

    // MARK: - Provenance Export

    @objc func exportProvenanceShell(_ sender: Any?) {
        exportProvenance(format: .shell)
    }

    @objc func exportProvenancePython(_ sender: Any?) {
        exportProvenance(format: .python)
    }

    @objc func exportProvenanceNextflow(_ sender: Any?) {
        exportProvenance(format: .nextflow)
    }

    @objc func exportProvenanceSnakemake(_ sender: Any?) {
        exportProvenance(format: .snakemake)
    }

    @objc func exportProvenanceMethods(_ sender: Any?) {
        exportProvenance(format: .methods)
    }

    @objc func exportProvenanceJSON(_ sender: Any?) {
        exportProvenance(format: .json)
    }

    private func exportProvenance(format: ProvenanceExportFormat) {
        // Find provenance for the currently selected/displayed file
        let run: WorkflowRun?

        // Try the selected sidebar item first
        if let selectedURL = mainWindowController?.mainSplitViewController?.sidebarController?.selectedFileURL {
            run = ProvenanceRecorder.findProvenance(forFile: selectedURL)
        } else {
            // Fall back to most recent completed run
            Task {
                let runs = await ProvenanceRecorder.shared.allRuns()
                let completedRun = runs.first { $0.status == .completed }
                if let completedRun {
                    self.presentProvenanceExportSheet(run: completedRun, format: format)
                } else {
                    self.showNoProvenanceAlert()
                }
            }
            return
        }

        guard let run else {
            showNoProvenanceAlert()
            return
        }

        presentProvenanceExportSheet(run: run, format: format)
    }

    private func presentProvenanceExportSheet(run: WorkflowRun, format: ProvenanceExportFormat) {
        let exporter = ProvenanceExporter()
        let content: String
        do {
            content = try exporter.export(run, format: format)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export Failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = format.defaultFilename
        savePanel.allowedContentTypes = [.plainText]
        savePanel.canCreateDirectories = true

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else {
            return
        }

        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                debugLog("Provenance exported to \(url.path)")

                // Make shell/python scripts executable
                if format == .shell || format == .python {
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: url.path
                    )
                }
            } catch {
                debugLog("Provenance export write failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = "Could not write file: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func showNoProvenanceAlert() {
        let alert = NSAlert()
        alert.messageText = "No Provenance Available"
        alert.informativeText = "No provenance record was found for the selected file. Provenance is recorded when files are created through tool operations (assembly, import, conversion, etc.)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    private func showNotImplementedAlert(_ feature: String) {
        let alert = NSAlert()
        alert.messageText = "Feature Not Yet Implemented"
        alert.informativeText = "\(feature) will be available in a future release."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = mainWindowController?.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    // MARK: - Import ONT Run

    @objc func importONTRun(_ sender: Any?) {
        guard let projectURL = workingDirectoryURL else {
            let alert = NSAlert()
            alert.messageText = "No Project Open"
            alert.informativeText = "Please open or create a project before importing an ONT run."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = mainWindowController?.window ?? NSApp.keyWindow {
                alert.beginSheetModal(for: window)
            }
            return
        }

        guard let window = mainWindowController?.window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select an ONT output directory (fastq_pass, a barcoded folder, or a folder with FASTQ chunks)"
        panel.prompt = "Import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.mainWindowController?.mainSplitViewController?.importONTDirectoryInBackground(
                sourceURL: url,
                projectURL: projectURL
            )
        }
    }

    // MARK: - Export FASTQ

    @objc func exportFASTQ(_ sender: Any?) {
        guard let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController else {
            showExportError(message: "No sidebar available.")
            return
        }

        let items = sidebarController.selectedItems().filter { $0.type == .fastqBundle && $0.url != nil }
        guard !items.isEmpty else {
            showExportError(message: "No FASTQ datasets selected. Select one or more FASTQ bundles in the sidebar.")
            return
        }

        guard let window = mainWindowController?.window else { return }

        if items.count == 1 {
            // Single selection: use save panel
            let item = items[0]
            let bundleURL = item.url!
            let isDerived = FASTQBundle.isDerivedBundle(bundleURL)
            let baseName = FASTQBundle.deriveBaseName(from: bundleURL)
            let suggestedName: String
            if isDerived {
                suggestedName = baseName + ".fastq.gz"
            } else if let primaryURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
                suggestedName = primaryURL.lastPathComponent
            } else {
                suggestedName = baseName + ".fastq"
            }

            let savePanel = NSSavePanel()
            savePanel.title = "Export FASTQ"
            savePanel.nameFieldStringValue = suggestedName
            savePanel.allowedContentTypes = [.data]
            savePanel.canCreateDirectories = true
            savePanel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let outputURL = savePanel.url else { return }
                self?.performFASTQExports(
                    bundles: [(bundleURL, outputURL, isDerived, item.title)],
                    window: window
                )
            }
        } else {
            // Multi-selection: use open panel (folder picker)
            let openPanel = NSOpenPanel()
            openPanel.title = "Export \(items.count) FASTQ Files — Choose Output Folder"
            openPanel.canChooseFiles = false
            openPanel.canChooseDirectories = true
            openPanel.canCreateDirectories = true
            openPanel.prompt = "Export Here"
            openPanel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let folderURL = openPanel.url else { return }
                var bundles: [(bundleURL: URL, outputURL: URL, isDerived: Bool, title: String)] = []
                for item in items {
                    let bundleURL = item.url!
                    let isDerived = FASTQBundle.isDerivedBundle(bundleURL)
                    let baseName = FASTQBundle.deriveBaseName(from: bundleURL)
                    let filename: String
                    if isDerived {
                        filename = baseName + ".fastq.gz"
                    } else if let primaryURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
                        filename = primaryURL.lastPathComponent
                    } else {
                        filename = baseName + ".fastq"
                    }
                    let outputURL = folderURL.appendingPathComponent(filename)
                    bundles.append((bundleURL, outputURL, isDerived, item.title))
                }
                self?.performFASTQExports(bundles: bundles, window: window)
            }
        }
    }

    /// Exports one or more FASTQ bundles in the background.
    private func performFASTQExports(
        bundles: [(bundleURL: URL, outputURL: URL, isDerived: Bool, title: String)],
        window: NSWindow
    ) {
        let total = bundles.count
        Task.detached {
            var succeeded = 0
            var failed: [(title: String, error: String)] = []

            for (bundleURL, outputURL, isDerived, title) in bundles {
                do {
                    if isDerived {
                        try await FASTQDerivativeService.shared.exportMaterializedFASTQ(
                            fromDerivedBundle: bundleURL,
                            to: outputURL,
                            progress: { message in
                                debugLog("Export FASTQ (\(title)): \(message)")
                            }
                        )
                    } else {
                        guard let primaryURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) else {
                            throw NSError(domain: "com.lungfish.browser", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "No FASTQ file found inside bundle"])
                        }
                        try FileManager.default.copyItem(at: primaryURL, to: outputURL)
                    }
                    succeeded += 1
                } catch {
                    debugLog("Export FASTQ failed for \(title): \(error)")
                    failed.append((title, error.localizedDescription))
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let alert = NSAlert()
                    if failed.isEmpty {
                        alert.messageText = "Export Complete"
                        if total == 1 {
                            alert.informativeText = "\(bundles[0].title) exported as \(bundles[0].outputURL.lastPathComponent)."
                        } else {
                            alert.informativeText = "Successfully exported \(succeeded) FASTQ file(s)."
                        }
                        alert.alertStyle = .informational
                        alert.addButton(withTitle: "OK")
                        if total == 1 {
                            alert.addButton(withTitle: "Show in Finder")
                        }
                    } else if succeeded == 0 {
                        alert.messageText = "Export Failed"
                        alert.informativeText = failed.map { "\($0.title): \($0.error)" }.joined(separator: "\n")
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "OK")
                    } else {
                        alert.messageText = "Export Partially Complete"
                        alert.informativeText = "\(succeeded) succeeded, \(failed.count) failed.\n\n"
                            + failed.map { "\($0.title): \($0.error)" }.joined(separator: "\n")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                    }
                    alert.beginSheetModal(for: window) { response in
                        if total == 1 && failed.isEmpty && response == .alertSecondButtonReturn {
                            NSWorkspace.shared.activateFileViewerSelecting([bundles[0].outputURL])
                        }
                    }
                }
            }
        }
    }

    // MARK: - OperationsMenuActions

    private var operationsPanelController: OperationsPanelController?

    @objc func showOperationsPanel(_ sender: Any?) {
        if operationsPanelController == nil {
            operationsPanelController = OperationsPanelController()
        }
        operationsPanelController?.showWindow(nil)
    }

    @objc func cancelAllOperations(_ sender: Any?) {
        let runningCount = OperationCenter.shared.activeCount
        guard runningCount > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "Cancel All Operations?"
        alert.informativeText = "This will cancel \(runningCount) running operation\(runningCount == 1 ? "" : "s")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Operations")
        alert.addButton(withTitle: "Keep Running")

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                OperationCenter.shared.cancelAll()
            }
        }
    }

    @objc func clearCompletedOperations(_ sender: Any?) {
        OperationCenter.shared.clearCompleted()
    }

    @objc func cancelOperation(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let operationID = menuItem.representedObject as? UUID else { return }

        guard let item = OperationCenter.shared.items.first(where: { $0.id == operationID }),
              item.state == .running else { return }

        let alert = NSAlert()
        alert.messageText = "Cancel \"\(item.title)\"?"
        alert.informativeText = "This operation is \(Int(item.progress * 100))% complete."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel Operation")
        alert.addButton(withTitle: "Keep Running")

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else { return }
        Task {
            let response = await alert.beginSheetModal(for: window)
            if response == .alertFirstButtonReturn {
                OperationCenter.shared.cancel(id: operationID)
            }
        }
    }

    // MARK: - HelpMenuActions

    private func showHelpTopic(_ topicID: String) {
        // Prefer macOS Help Book integration for indexed, searchable docs.
        if HelpBookIntegration.openTopic(topicID) {
            return
        }

        // Fallback to the in-app help browser if Help Book resources are unavailable.
        if helpWindowController == nil {
            helpWindowController = HelpWindowController()
        }
        helpWindowController?.showTopic(topicID)
    }

    @objc func showLungfishHelp(_ sender: Any?) {
        showHelpTopic("index")
    }

    @objc func showGettingStarted(_ sender: Any?) {
        showHelpTopic("getting-started")
    }

    @objc func showVCFGuide(_ sender: Any?) {
        showHelpTopic("vcf-variants")
    }

    @objc func showAIGuide(_ sender: Any?) {
        showHelpTopic("ai-assistant")
    }

    @objc func openReleaseNotes(_ sender: Any?) {
        if let url = URL(string: "https://github.com/dho/lungfish-genome-browser/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func reportIssue(_ sender: Any?) {
        if let url = URL(string: "https://github.com/dho/lungfish-genome-browser/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - GenBankParser for synchronous parsing

/// Simple synchronous parser for GenBank files.
/// This avoids async/await and MainActor completely.
private class GenBankParser {

    func parseContent(_ content: String) throws -> [GenBankRecord] {
        let lines = content.components(separatedBy: .newlines)
        var records: [GenBankRecord] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            // Skip empty lines between records
            while lineIndex < lines.count && lines[lineIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                lineIndex += 1
            }

            if lineIndex >= lines.count {
                break
            }

            // Parse a single record
            let (record, nextIndex) = try parseRecord(lines: lines, startIndex: lineIndex)
            if let record = record {
                records.append(record)
            }
            lineIndex = nextIndex
        }

        return records
    }

    private func parseRecord(lines: [String], startIndex: Int) throws -> (GenBankRecord?, Int) {
        var lineIndex = startIndex
        var locusName: String?
        var locusLength = 0
        var locusMoleculeType: MoleculeType = .dna
        var locusTopology: Topology = .linear
        var locusDivision: String?
        var locusDate: String?
        var definition: String?
        var accession: String?
        var version: String?
        var features: [SequenceAnnotation] = []
        var sequenceBases = ""

        enum Section {
            case header
            case features
            case origin
        }
        var currentSection = Section.header
        var currentFeatureType: String?
        var currentFeatureLocation: String?
        var currentQualifiers: [String: String] = [:]
        var currentQualifierKey: String?
        var currentQualifierValue: String = ""

        while lineIndex < lines.count {
            let line = lines[lineIndex]

            // Check for record terminator
            if line.hasPrefix("//") {
                // Save any pending feature
                if let featureType = currentFeatureType,
                   let location = currentFeatureLocation {
                    if let annotation = createAnnotation(type: featureType, location: location, qualifiers: currentQualifiers) {
                        features.append(annotation)
                    }
                }
                lineIndex += 1
                break
            }

            switch currentSection {
            case .header:
                if line.hasPrefix("LOCUS") {
                    let parsed = parseLocusLine(line)
                    locusName = parsed.name
                    locusLength = parsed.length
                    locusMoleculeType = parsed.moleculeType
                    locusTopology = parsed.topology
                    locusDivision = parsed.division
                    locusDate = parsed.date
                } else if line.hasPrefix("DEFINITION") {
                    definition = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("ACCESSION") {
                    accession = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("VERSION") {
                    version = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("FEATURES") {
                    currentSection = .features
                } else if line.hasPrefix("ORIGIN") {
                    currentSection = .origin
                }

            case .features:
                if line.hasPrefix("ORIGIN") {
                    // Save any pending feature
                    if let featureType = currentFeatureType,
                       let location = currentFeatureLocation {
                        if let annotation = createAnnotation(type: featureType, location: location, qualifiers: currentQualifiers) {
                            features.append(annotation)
                        }
                    }
                    currentSection = .origin
                } else if line.count >= 21 && !line.hasPrefix(" ") {
                    // New section - shouldn't happen but handle it
                    break
                } else if line.count >= 21 {
                    let featureKey = String(line.prefix(21)).trimmingCharacters(in: .whitespaces)
                    let rest = line.count > 21 ? String(line.dropFirst(21)) : ""

                    if !featureKey.isEmpty && !featureKey.hasPrefix("/") {
                        // Save previous feature
                        if let featureType = currentFeatureType,
                           let location = currentFeatureLocation {
                            if let annotation = createAnnotation(type: featureType, location: location, qualifiers: currentQualifiers) {
                                features.append(annotation)
                            }
                        }

                        // Start new feature
                        currentFeatureType = featureKey
                        currentFeatureLocation = rest.trimmingCharacters(in: .whitespaces)
                        currentQualifiers = [:]
                        currentQualifierKey = nil
                        currentQualifierValue = ""
                    } else if featureKey.isEmpty || featureKey.hasPrefix("/") {
                        // Continuation or qualifier
                        let trimmed = rest.trimmingCharacters(in: .whitespaces)

                        if trimmed.hasPrefix("/") {
                            // Save previous qualifier
                            if let key = currentQualifierKey {
                                currentQualifiers[key] = currentQualifierValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                            }

                            // Parse new qualifier
                            let qualLine = String(trimmed.dropFirst())
                            if let eqIndex = qualLine.firstIndex(of: "=") {
                                currentQualifierKey = String(qualLine[..<eqIndex])
                                currentQualifierValue = String(qualLine[qualLine.index(after: eqIndex)...])
                            } else {
                                currentQualifierKey = qualLine
                                currentQualifierValue = "true"
                            }
                        } else if currentQualifierKey != nil {
                            // Continuation of qualifier value
                            currentQualifierValue += trimmed
                        } else if currentFeatureLocation != nil {
                            // Continuation of location
                            currentFeatureLocation! += trimmed
                        }
                    }
                }

            case .origin:
                // Parse sequence lines
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !trimmed.hasPrefix("//") {
                    // Remove line numbers and spaces
                    let bases = trimmed.filter { $0.isLetter }
                    sequenceBases += bases
                }
            }

            lineIndex += 1
        }

        // Create the record
        guard let name = locusName else {
            return (nil, lineIndex)
        }

        // Create LocusInfo using the proper LungfishIO types
        let locusInfo = LocusInfo(
            name: name,
            length: locusLength,
            moleculeType: locusMoleculeType,
            topology: locusTopology,
            division: locusDivision,
            date: locusDate
        )

        // Create the sequence
        let sequence = try Sequence(
            name: name,
            description: definition,
            alphabet: locusMoleculeType.alphabet,
            bases: sequenceBases
        )

        // Create the record using the proper GenBankRecord initializer
        let record = GenBankRecord(
            sequence: sequence,
            annotations: features,
            locus: locusInfo,
            definition: definition,
            accession: accession,
            version: version
        )

        return (record, lineIndex)
    }

    private func parseLocusLine(_ line: String) -> (name: String, length: Int, moleculeType: MoleculeType, topology: Topology, division: String?, date: String?) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            return ("unknown", 0, .dna, .linear, nil, nil)
        }

        let name = String(parts[1])
        var length = 0
        var moleculeType: MoleculeType = .dna
        var topology: Topology = .linear
        var division: String?
        var date: String?

        for (index, part) in parts.enumerated() {
            let partStr = String(part)
            if partStr == "bp" && index > 0 {
                length = Int(parts[index - 1]) ?? 0
            } else if let molType = MoleculeType(rawValue: partStr.uppercased()) {
                moleculeType = molType
            } else if let molType = MoleculeType(rawValue: partStr) {
                moleculeType = molType
            } else if partStr.lowercased() == "circular" {
                topology = .circular
            } else if partStr.lowercased() == "linear" {
                topology = .linear
            }
        }

        // Get division and date from end
        if parts.count >= 2 {
            let lastPart = String(parts.last!)
            if lastPart.contains("-") {
                date = lastPart
                if parts.count >= 3 {
                    let secondLast = String(parts[parts.count - 2])
                    // Division codes are typically 3 uppercase letters
                    if secondLast.count == 3 && secondLast.uppercased() == secondLast {
                        division = secondLast
                    }
                }
            }
        }

        return (name, length, moleculeType, topology, division, date)
    }

    private func createAnnotation(type: String, location: String, qualifiers: [String: String]) -> SequenceAnnotation? {
        // Parse location to get start and end
        let (start, end, strand) = parseLocation(location)
        guard start >= 0 && end >= start else { return nil }

        let name = qualifiers["gene"] ?? qualifiers["product"] ?? qualifiers["label"] ?? type
        let annotationType = AnnotationType(rawValue: type.lowercased()) ?? .region

        return SequenceAnnotation(
            type: annotationType,
            name: name,
            intervals: [AnnotationInterval(start: start, end: end)],
            strand: strand,
            qualifiers: qualifiers.mapValues { AnnotationQualifier($0) }
        )
    }

    private func parseLocation(_ location: String) -> (start: Int, end: Int, strand: Strand) {
        var loc = location
        var strand: Strand = .forward

        // Handle complement
        if loc.hasPrefix("complement(") {
            strand = .reverse
            loc = String(loc.dropFirst(11).dropLast())
        }

        // Handle join - just take first range for simplicity
        if loc.hasPrefix("join(") {
            loc = String(loc.dropFirst(5).dropLast())
            if let firstRange = loc.split(separator: ",").first {
                loc = String(firstRange)
            }
        }

        // Parse range
        let parts = loc.replacingOccurrences(of: "<", with: "")
                      .replacingOccurrences(of: ">", with: "")
                      .split(separator: ".")

        if parts.count >= 2 {
            let start = Int(parts[0]) ?? 0
            let end = Int(parts.last!) ?? 0
            return (start - 1, end, strand)  // Convert to 0-based
        } else if let single = Int(loc.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "")) {
            return (single - 1, single, strand)
        }

        return (0, 0, strand)
    }
}

// MARK: - Export Filename Updater

/// Helper that updates NSSavePanel filename when format/compression popups change.
private class ExportFilenameUpdater: NSObject {
    nonisolated(unsafe) static var associatedKey: UInt8 = 0
    weak var panel: NSSavePanel?
    let baseName: String
    let formatPopup: NSPopUpButton
    let compPopup: NSPopUpButton

    init(panel: NSSavePanel, baseName: String, formatPopup: NSPopUpButton, compPopup: NSPopUpButton) {
        self.panel = panel
        self.baseName = baseName
        self.formatPopup = formatPopup
        self.compPopup = compPopup
    }

    @objc func popupChanged(_ sender: Any?) {
        let formatExt = formatPopup.indexOfSelectedItem == 1 ? "gbk" : "fa"
        let compExt: String
        switch compPopup.indexOfSelectedItem {
        case 1: compExt = ".gz"
        case 2: compExt = ".zst"
        default: compExt = ""
        }
        panel?.nameFieldStringValue = "\(baseName).\(formatExt)\(compExt)"
    }
}
