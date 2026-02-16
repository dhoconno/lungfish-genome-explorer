// AppDelegate.swift - Application lifecycle management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers
import os

/// Debug logging to file for troubleshooting (only writes to disk in DEBUG builds)
private func debugLog(_ message: String) {
    #if DEBUG
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let threadInfo = Thread.isMainThread ? "main" : "bg"
    let logMessage = "[\(timestamp)][\(threadInfo)] \(message)\n"
    print("[\(threadInfo)] \(message)")  // Also print to console
    if let data = logMessage.data(using: .utf8) {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("lungfish-debug.log")
        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        }
    }
    #endif
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
    FileMenuActions, ViewMenuActions, SequenceMenuActions, ToolsMenuActions, HelpMenuActions {

    /// The shared application delegate instance
    public static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// Main window controller for the application
    public var mainWindowController: MainWindowController?

    /// Welcome window controller for project selection
    private var welcomeWindowController: WelcomeWindowController?

    /// Settings window controller (lazy singleton)
    private var settingsWindowController: SettingsWindowController?

    /// AI Assistant window controller (lazy singleton)
    private var aiAssistantWindowController: AIAssistantWindowController?

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

        // Configure application appearance
        configureAppearance()

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

    private func showMainWindowWithProject(_ projectURL: URL) {
        // Set as working directory
        workingDirectoryURL = projectURL

        // Create and show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Activate the app to ensure menu bar switches properly
        NSApp.activate(ignoringOtherApps: true)

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil

        // Use the new filesystem-backed sidebar model via DocumentManager
        // This posts projectOpenedNotification which triggers sidebarController.openProject(at:)
        // The FileSystemWatcher will automatically refresh the sidebar when files change
        do {
            let _ = try DocumentManager.shared.openProject(at: projectURL)
            debugLog("showMainWindowWithProject: Opened project via DocumentManager")
        } catch {
            debugLog("showMainWindowWithProject: Failed to open project: \(error.localizedDescription)")
            // Fall back to just showing the sidebar with filesystem view
            mainWindowController?.mainSplitViewController?.sidebarController.openProject(at: projectURL)
        }
    }

    private func showMainWindowWithoutProject() {
        // Create and show the main window without a project
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Activate the app to ensure menu bar switches properly
        NSApp.activate(ignoringOtherApps: true)

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
    /// - Shows the file list immediately (UI remains responsive)
    /// - Loads file content in the background without blocking MainActor
    /// - Updates sidebar items as files are parsed
    private func loadProjectFolderAsync(_ url: URL) {
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController

        // Phase 1: Fast folder scan (synchronous, just reads directory entries)
        let scannedFiles: [FileScanResult]
        do {
            scannedFiles = try DocumentLoader.scanFolder(at: url)
        } catch {
            debugLog("loadProjectFolderAsync: Scan failed - \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Failed to Scan Project"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        guard !scannedFiles.isEmpty else {
            debugLog("loadProjectFolderAsync: Empty folder")
            // Still add the folder to sidebar (empty project)
            sidebarController?.addProjectFolder(url, documents: [])
            viewerController?.showNoSequenceSelected()
            return
        }

        debugLog("loadProjectFolderAsync: Found \(scannedFiles.count) files")

        // Phase 2: Create placeholder documents for sidebar (immediate UI response)
        var placeholderDocuments: [LoadedDocument] = []
        for scan in scannedFiles {
            let doc = LoadedDocument(url: scan.url, type: scan.type)
            // Document is a placeholder - sequences/annotations are empty
            placeholderDocuments.append(doc)
        }

        // Update sidebar with placeholder items immediately
        sidebarController?.addProjectFolder(url, documents: placeholderDocuments)
        debugLog("loadProjectFolderAsync: Sidebar populated with \(placeholderDocuments.count) placeholders")

        // Phase 3: Background loading for each file
        // Track first document display using lock-protected state for thread safety
        final class DisplayTracker: @unchecked Sendable {
            private let lock = NSLock()
            private var _displayedFirst = false
            var displayedFirst: Bool {
                get { lock.lock(); defer { lock.unlock() }; return _displayedFirst }
                set { lock.lock(); defer { lock.unlock() }; _displayedFirst = newValue }
            }
        }
        let tracker = DisplayTracker()

        for scan in scannedFiles {
            Task { [weak self] in
                do {
                    let result = try await DocumentLoader.loadFile(at: scan.url, type: scan.type)

                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        let viewerController = self.mainWindowController?.mainSplitViewController?.viewerController
                        let sidebarController = self.mainWindowController?.mainSplitViewController?.sidebarController

                        // Create and populate document with loaded content
                        let document = LoadedDocument(url: result.url, type: result.type)
                        document.sequences = result.sequences
                        document.annotations = result.annotations

                        // Register with DocumentManager (replaces placeholder if exists)
                        DocumentManager.shared.registerDocument(document)

                        // Refresh sidebar item to show loaded state
                        sidebarController?.refreshItem(for: result.url)

                        // Display first successfully loaded document with sequences
                        if !tracker.displayedFirst && !result.sequences.isEmpty {
                            tracker.displayedFirst = true
                            viewerController?.displayDocument(document)
                            debugLog("loadProjectFolderAsync: Displayed first document: \(document.name)")
                        }
                    }
                } catch {
                    debugLog("loadProjectFolderAsync: Failed to load \(scan.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Internal method for testing - loads a project folder without dialog.
    ///
    /// Note: No loading spinner shown - follows same pattern as loadProjectFolderAsync().
    private func loadProjectFolderForTesting(_ url: URL) async {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        do {
            let documents = try await DocumentManager.shared.loadProjectFolder(at: url)

            if !documents.isEmpty {
                sidebarController?.addProjectFolder(url, documents: documents)

                if let firstDoc = documents.first {
                    viewerController?.displayDocument(firstDoc)
                }
            } else {
                // Empty project - show clear empty state
                viewerController?.showNoSequenceSelected()
            }
        } catch {
            // Error handling - no spinner to hide
        }
    }

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

    private func configureAppearance() {
        // Use system appearance (respects Dark Mode)
        // No custom appearance overrides - follow HIG
    }

    private func registerNotifications() {
        // Register for relevant system notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
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
        // Handle window close events
    }

    private func saveApplicationState() {
        // Persist user preferences and window state
        UserDefaults.standard.synchronize()
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
                alert.runModal()
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
        panel.allowedContentTypes = [
            .init(filenameExtension: "fa")!,
            .init(filenameExtension: "fasta")!,
            .init(filenameExtension: "fna")!,
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
        panel.message = "Select a folder containing genomic data files"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self = self else { return }

            // Set as working directory
            self.workingDirectoryURL = url

            // Use the new filesystem-backed sidebar model
            // This automatically scans the directory and sets up FileSystemWatcher
            do {
                let _ = try DocumentManager.shared.openProject(at: url)
                debugLog("openProjectFolder: Opened project via DocumentManager")
            } catch {
                debugLog("openProjectFolder: Failed to open project: \(error.localizedDescription)")
                // Fall back to just showing the sidebar with filesystem view
                let sidebarController = self.mainWindowController?.mainSplitViewController?.sidebarController
                sidebarController?.openProject(at: url)
            }
        }
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
        guard let projectURL = workingDirectoryURL else {
            // No project open - show alert
            let alert = NSAlert()
            alert.messageText = "No Project Open"
            alert.informativeText = "Please open or create a project before importing files."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
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
                debugLog("importFiles: Starting file copy operation")

                // Get references to UI components
                let activityIndicator = self.mainWindowController?.mainSplitViewController?.activityIndicator
                let sidebarController = self.mainWindowController?.mainSplitViewController?.sidebarController

                // Show progress indicator
                let fileCount = selectedURLs.count
                activityIndicator?.show(
                    message: "Importing \(fileCount) file\(fileCount == 1 ? "" : "s")...",
                    style: .indeterminate
                )

                var importedURLs: [URL] = []
                var skippedCount = 0
                var errorCount = 0

                for (index, sourceURL) in selectedURLs.enumerated() {
                    let filename = sourceURL.lastPathComponent
                    let destinationURL = projectURL.appendingPathComponent(filename)

                    // Update progress message
                    activityIndicator?.updateMessage("Importing \(filename) (\(index + 1)/\(fileCount))...")

                    debugLog("importFiles: Copying \(filename) to project")

                    // Check for duplicate
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        debugLog("importFiles: File already exists, skipping: \(filename)")
                        skippedCount += 1
                        continue
                    }

                    do {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                        importedURLs.append(destinationURL)
                        debugLog("importFiles: Successfully copied \(filename)")
                    } catch {
                        debugLog("importFiles: Failed to copy \(filename): \(error.localizedDescription)")
                        errorCount += 1
                    }
                }

                // Hide progress indicator
                activityIndicator?.hide()

                // Force sidebar refresh immediately (don't wait for FileSystemWatcher)
                sidebarController?.reloadFromFilesystem()
                debugLog("importFiles: Triggered sidebar refresh")

                if importedURLs.isEmpty && skippedCount == 0 && errorCount == 0 {
                    debugLog("importFiles: No files imported")
                } else {
                    debugLog("importFiles: Imported \(importedURLs.count), skipped \(skippedCount), errors \(errorCount)")
                }
            }
        }
    }

    @objc func importVCFToBundle(_ sender: Any?) {
        debugLog("importVCFToBundle: Menu action triggered")

        // Require a bundle to be loaded
        guard let viewerController = mainWindowController?.mainSplitViewController?.viewerController,
              let bundleURL = viewerController.currentBundleURL else {
            showAlert(title: "No Bundle Loaded", message: "Please open a reference genome bundle before importing VCF variants.")
            return
        }

        guard let window = mainWindowController?.window else {
            debugLog("importVCFToBundle: No main window available")
            return
        }

        // Show NSOpenPanel for VCF files
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
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
        panel.message = "Select a VCF file to import into the current bundle"
        panel.prompt = "Import"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let vcfURL = panel.url else {
                debugLog("importVCFToBundle: User cancelled")
                return
            }
            debugLog("importVCFToBundle: Selected \(vcfURL.lastPathComponent)")
            self?.performVCFImport(vcfURL: vcfURL, bundleURL: bundleURL)
        }
    }

    private func performVCFImport(vcfURL: URL, bundleURL: URL) {
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        let selectedImportProfile = selectedVCFImportProfile()
        let profileLabel = Self.importProfileLabel(selectedImportProfile)
        mainWindowController?.mainSplitViewController?.activityIndicator?.show(
            message: "Importing VCF variants (\(profileLabel))...",
            style: .determinate(progress: 0),
            cancellable: true
        )
        mainWindowController?.mainSplitViewController?.activityIndicator?.onCancel = {
            cancelFlag.withLock { $0 = true }
        }
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

                // Remove existing database if re-importing
                if FileManager.default.fileExists(atPath: dbURL.path) {
                    try FileManager.default.removeItem(at: dbURL)
                }

                debugLog("performVCFImport: Creating variant database at \(dbURL.lastPathComponent) via helper")

                let variantCount = try Self.runVCFImportViaHelper(
                    vcfURL: vcfURL,
                    outputDBURL: dbURL,
                    sourceFile: vcfURL.lastPathComponent,
                    importProfile: selectedImportProfile,
                    shouldCancel: isCancelled,
                    progressHandler: { [weak self] progress, message in
                        let clampedProgress = max(0.0, min(1.0, progress))
                        let etaText = Self.estimatedRemainingText(progress: clampedProgress, startedAt: importStartedAt)
                        scheduleOnMainRunLoop {
                            self?.mainWindowController?.mainSplitViewController?.activityIndicator?.updateProgress(clampedProgress)
                            let displayMessage = etaText.isEmpty ? message : "\(message) • \(etaText)"
                            self?.mainWindowController?.mainSplitViewController?.activityIndicator?.updateMessage(displayMessage)
                        }
                    }
                )

                debugLog("performVCFImport: Created database with \(variantCount) variants")
                if isCancelled() {
                    throw VariantDatabaseError.cancelled
                }

                // Normalize chromosome names to match the bundle
                let currentManifestForChrom = try BundleManifest.load(from: bundleURL)
                let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                let vcfChroms = rwDB.allChromosomes()
                let chromMapping = mapVCFChromosomes(vcfChroms, toBundleChromosomes: currentManifestForChrom.genome.chromosomes)
                if !chromMapping.isEmpty {
                    try rwDB.renameChromosomes(chromMapping)
                    debugLog("performVCFImport: Remapped chromosomes: \(chromMapping)")
                }
                if isCancelled() {
                    throw VariantDatabaseError.cancelled
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

            // Use CFRunLoopPerformBlock to bypass GCD main queue stalls
            // (DispatchQueue.main.async can be blocked after sheet dismissal)
            scheduleOnMainRunLoop { [weak self] in
                debugLog("performVCFImport: Main thread callback executing")
                self?.mainWindowController?.mainSplitViewController?.activityIndicator?.onCancel = nil
                self?.mainWindowController?.mainSplitViewController?.activityIndicator?.hide()

                switch result {
                case .success(let (variantCount, _)):
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
                    } else {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "--vcf-import-helper",
            "--vcf-path", vcfURL.path,
            "--output-db-path", outputDBURL.path,
            "--source-file", sourceFile,
            "--import-profile", importProfile.rawValue,
        ]

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
                    progressHandler(progress, event.message ?? "Importing VCF...")
                }
            case "done":
                if let variantCount = event.variantCount {
                    parseState.withLock { $0.variantCount = variantCount }
                }
            case "error":
                let message = event.error ?? event.message ?? "VCF helper import failed"
                parseState.withLock { $0.helperError = message }
            case "cancelled":
                parseState.withLock { $0.wasCancelled = true }
            default:
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
            throw VariantDatabaseError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let helperError = parseState.withLock { $0.helperError }
            let stderrMessage = stderrState.withLock { data -> String in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let message = helperError ?? (stderrMessage.isEmpty ? "VCF helper exited with status \(process.terminationStatus)" : stderrMessage)
            throw VariantDatabaseError.createFailed(message)
        }

        if let variantCount = parseState.withLock({ $0.variantCount }) {
            return variantCount
        }

        let importedDB = try VariantDatabase(url: outputDBURL)
        return importedDB.totalCount()
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

    @objc func exportFASTA(_ sender: Any?) {
        // Get current document
        guard let document = mainWindowController?.mainSplitViewController?.viewerController?.currentDocument else {
            showExportError(message: "No document is currently open.")
            return
        }

        // Check if there are sequences to export
        guard !document.sequences.isEmpty else {
            showExportError(message: "The current document has no sequences to export.")
            return
        }

        // Show save panel
        let panel = NSSavePanel()
        panel.title = "Export FASTA"
        panel.allowedContentTypes = [UTType(filenameExtension: "fa")!]
        panel.nameFieldStringValue = document.name.replacingOccurrences(of: ".\(document.url.pathExtension)", with: "") + ".fa"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            do {
                let writer = FASTAWriter(url: url)
                try writer.write(document.sequences)

                debugLog("exportFASTA: Successfully exported \(document.sequences.count) sequences to \(url.path)")

                self?.showExportSuccess(filename: url.lastPathComponent, count: document.sequences.count, itemType: "sequence")
            } catch {
                debugLog("exportFASTA: Export failed - \(error.localizedDescription)")
                self?.showExportError(message: "Failed to export FASTA: \(error.localizedDescription)")
            }
        }
    }

    @objc func exportGenBank(_ sender: Any?) {
        // Get current document
        guard let document = mainWindowController?.mainSplitViewController?.viewerController?.currentDocument else {
            showExportError(message: "No document is currently open.")
            return
        }

        // Check if there are sequences to export
        guard !document.sequences.isEmpty else {
            showExportError(message: "The current document has no sequences to export.")
            return
        }

        // Show save panel
        let panel = NSSavePanel()
        panel.title = "Export GenBank"
        panel.allowedContentTypes = [UTType(filenameExtension: "gb")!]
        panel.nameFieldStringValue = document.name.replacingOccurrences(of: ".\(document.url.pathExtension)", with: "") + ".gb"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }

            do {
                // Create GenBankRecords from document sequences and annotations
                var records: [GenBankRecord] = []

                for sequence in document.sequences {
                    // Filter annotations for this sequence
                    let sequenceAnnotations = document.annotations.filter { annotation in
                        // Match by chromosome field if set, otherwise include all
                        annotation.chromosome == nil || annotation.chromosome == sequence.name
                    }

                    // Determine molecule type from sequence alphabet
                    let moleculeType: MoleculeType
                    switch sequence.alphabet {
                    case .dna:
                        moleculeType = .dna
                    case .rna:
                        moleculeType = .rna
                    case .protein:
                        moleculeType = .protein
                    }

                    // Create locus info
                    let locus = LocusInfo(
                        name: sequence.name,
                        length: sequence.length,
                        moleculeType: moleculeType,
                        topology: .linear,
                        division: nil,
                        date: Self.currentDateString()
                    )

                    // Create the record
                    let record = GenBankRecord(
                        sequence: sequence,
                        annotations: sequenceAnnotations,
                        locus: locus,
                        definition: sequence.description,
                        accession: nil,
                        version: nil
                    )

                    records.append(record)
                }

                let writer = GenBankWriter(url: url)
                try writer.write(records)

                debugLog("exportGenBank: Successfully exported \(records.count) records to \(url.path)")

                self?.showExportSuccess(filename: url.lastPathComponent, count: records.count, itemType: "record")
            } catch {
                debugLog("exportGenBank: Export failed - \(error.localizedDescription)")
                self?.showExportError(message: "Failed to export GenBank: \(error.localizedDescription)")
            }
        }
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
        // Image export requires rendering the viewer - not yet implemented
        showNotImplementedAlert("Image Export")
    }

    @objc func exportPDF(_ sender: Any?) {
        // PDF export requires rendering the viewer - not yet implemented
        showNotImplementedAlert("PDF Export")
    }

    /// Shows an error alert for export failures
    private func showExportError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Shows a success alert after export
    private func showExportSuccess(filename: String, count: Int, itemType: String) {
        let alert = NSAlert()
        alert.messageText = "Export Successful"
        let plural = count == 1 ? itemType : "\(itemType)s"
        alert.informativeText = "Successfully exported \(count) \(plural) to \(filename)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    @objc func setDisplayModeCollapsed(_ sender: Any?) {
        // TODO: Implement display mode change
    }

    @objc func setDisplayModeSquished(_ sender: Any?) {
        // TODO: Implement display mode change
    }

    @objc func setDisplayModeExpanded(_ sender: Any?) {
        // TODO: Implement display mode change
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

    /// Shows or toggles the AI assistant panel. Lazily creates the service and window controller.
    private func showOrToggleAIAssistant() {
        guard AppSettings.shared.aiSearchEnabled else {
            let alert = NSAlert()
            alert.messageText = "AI Assistant Disabled"
            alert.informativeText = "Enable AI-powered search in Settings > AI Services to use the assistant."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        if let controller = aiAssistantWindowController {
            controller.togglePanel()
            return
        }

        // First-time setup: create tool registry, service, and window controller
        let toolRegistry = AIToolRegistry()
        self.aiToolRegistry = toolRegistry

        // Wire the tool registry to the viewer's data
        connectToolRegistryToViewer(toolRegistry)

        let service = AIAssistantService(toolRegistry: toolRegistry)
        let controller = AIAssistantWindowController(service: service)
        self.aiAssistantWindowController = controller
        controller.showPanel()
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

        // Connect current view state callback
        toolRegistry.getCurrentViewState = { [weak self] in
            guard let viewerController = self?.mainWindowController?.mainSplitViewController?.viewerController else {
                return AIToolRegistry.ViewerState()
            }

            let provider = viewerController.currentBundleDataProvider
            let frame = viewerController.referenceFrame

            // Count variant tracks
            let variantTrackCount = viewerController.annotationSearchIndex?.variantDatabaseHandles.count ?? 0
            let totalVariantCount = viewerController.annotationSearchIndex?.variantDatabaseHandles.reduce(0) { $0 + $1.db.totalCount() } ?? 0

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
                totalVariantCount: totalVariantCount
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

        // "Import VCF Variants..." is only enabled when a bundle is loaded
        if menuItem.action == #selector(importVCFToBundle(_:)) {
            let hasBundle = mainWindowController?.mainSplitViewController?.viewerController?.currentBundleURL != nil
            return hasBundle
        }

        return true
    }

    // MARK: - SequenceMenuActions

    @objc func reverseComplement(_ sender: Any?) {
        // TODO: Implement reverse complement
    }

    @objc func translate(_ sender: Any?) {
        // TODO: Implement translation
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

        if alert.runModal() == .alertFirstButtonReturn {
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

    @objc func selectRegion(_ sender: Any?) {
        // TODO: Implement region selection
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

        if alert.runModal() == .alertFirstButtonReturn {
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

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func findORFs(_ sender: Any?) {
        // TODO: Implement ORF finding
    }

    @objc func findRestrictionSites(_ sender: Any?) {
        // TODO: Implement restriction site finding
    }

    // MARK: - ToolsMenuActions


    @objc func runSPAdes(_ sender: Any?) {
        showAssemblyConfigurationSheet(algorithm: .spades)
    }

    @objc func runMEGAHIT(_ sender: Any?) {
        showAssemblyConfigurationSheet(algorithm: .megahit)
    }

    /// Shows the assembly configuration sheet with the specified algorithm pre-selected.
    ///
    /// - Parameter algorithm: The assembly algorithm to pre-select (or nil for auto)
    private func showAssemblyConfigurationSheet(algorithm: AssemblyAlgorithm? = nil) {
        guard let window = mainWindowController?.window else {
            debugLog("showAssemblyConfigurationSheet: No main window available")
            return
        }

        debugLog("showAssemblyConfigurationSheet: Presenting assembly configuration for \(algorithm?.rawValue ?? "auto")")

        AssemblySheetPresenter.present(
            from: window,
            algorithm: algorithm,
            onComplete: { outputURL in
                debugLog("Assembly completed: \(outputURL.path)")

                // Show success message
                let alert = NSAlert()
                alert.messageText = "Assembly Complete"
                alert.informativeText = "Assembly output saved to:\n\(outputURL.path)"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open Folder")
                alert.addButton(withTitle: "OK")

                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(outputURL)
                }
            },
            onFailed: { error in
                debugLog("Assembly failed: \(error)")

                let alert = NSAlert()
                alert.messageText = "Assembly Failed"
                alert.informativeText = error
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.runModal()
            },
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
        // Use ENA service for SRA/FASTQ downloads
        showDatabaseBrowser(source: .ena)
    }

    @objc func searchPathoplexus(_ sender: Any?) {
        showDatabaseBrowser(source: .pathoplexus)
    }

    @objc func downloadGenomeAssembly(_ sender: Any?) {
        // TODO: Implement genome assembly download workflow with bundle building
        showNotImplementedAlert("Genome Assembly Download")
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
        browserWindow.title = "Search \(source.displayName)"

        window.beginSheet(browserWindow) { _ in
            debugLog("Sheet dismissed callback executing")
        }
    }

    /// Temporary storage for download URL while sheet is dismissing
    private var pendingDownloadTempURL: URL?

    /// Temporary storage for multiple download URLs while sheet is dismissing
    private var pendingDownloadTempURLs: [URL]?

    /// Synchronous version that handles the file and loads it immediately.
    ///
    /// This method is called from the sheet dismissal completion handler. Due to Swift concurrency
    /// integration issues with AppKit modal sessions, the MainActor may be blocked and unable to
    /// process async work.
    ///
    /// The solution is to:
    /// 1. Copy the file synchronously (we're already on MainActor)
    /// 2. Load file data on a GCD background thread (completely avoiding Swift concurrency)
    /// 3. Create LoadedDocument and update UI via Timer-based scheduling to MainActor
    private func handleDownloadedFileSync(at tempFileURL: URL) {
        debugLog("handleDownloadedFileSync: Starting with \(tempFileURL.path)")

        // Get UI controllers
        let activityIndicator = mainWindowController?.mainSplitViewController?.activityIndicator
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        // Show progress in the activity indicator
        let filename = tempFileURL.lastPathComponent
        activityIndicator?.show(message: "Importing \(filename)...", style: .indeterminate)

        // Determine destination
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
            debugLog("handleDownloadedFileSync: Failed to create directory - \(error)")
            activityIndicator?.hide()
            _ = openDocument(at: tempFileURL)
            return
        }

        // Generate unique filename
        let originalFilename = tempFileURL.lastPathComponent
        var destinationURL = destinationDirectory.appendingPathComponent(originalFilename)
        var counter = 1
        let fileExtension = tempFileURL.pathExtension
        let baseName = tempFileURL.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: destinationURL.path) {
            let newFilename = "\(baseName)_\(counter).\(fileExtension)"
            destinationURL = destinationDirectory.appendingPathComponent(newFilename)
            counter += 1
        }

        // Copy file
        do {
            try FileManager.default.copyItem(at: tempFileURL, to: destinationURL)
            debugLog("handleDownloadedFileSync: Copied to \(destinationURL.path)")
            try? FileManager.default.removeItem(at: tempFileURL)
        } catch {
            debugLog("handleDownloadedFileSync: Copy failed - \(error)")
            activityIndicator?.hide()
            _ = openDocument(at: tempFileURL)
            return
        }

        debugLog("handleDownloadedFileSync: viewerController=\(viewerController != nil), sidebarController=\(sidebarController != nil)")

        // Bundles are directories and should be surfaced directly in the sidebar.
        if destinationURL.pathExtension.lowercased() == "lungfishref" {
            activityIndicator?.hide()
            refreshSidebarAndSelectImportedURL(destinationURL)
            return
        }

        activityIndicator?.updateMessage("Loading \(destinationURL.lastPathComponent)...")

        debugLog("handleDownloadedFileSync: Starting background file load")

        // Load file data entirely on a background thread using GCD (no Swift concurrency).
        // This avoids the blocked MainActor issue completely.
        loadFileInBackground(at: destinationURL) { result in
            debugLog("handleDownloadedFileSync: Background load completed with result")

            // Now update UI on MainActor using Timer-based scheduling
            scheduleOnMainRunLoop { [weak activityIndicator, weak viewerController, weak sidebarController] in
                debugLog("handleDownloadedFileSync: scheduleOnMainRunLoop block executing")

                if let errorMessage = result.error {
                    debugLog("handleDownloadedFileSync: Error - \(errorMessage)")
                    activityIndicator?.hide()

                    let alert = NSAlert()
                    alert.messageText = "Failed to Load Downloaded File"
                    alert.informativeText = errorMessage
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }

                debugLog("handleDownloadedFileSync: Creating LoadedDocument with \(result.sequences.count) sequences")

                // Create LoadedDocument on MainActor
                let document = LoadedDocument(url: result.url, type: result.type)
                document.sequences = result.sequences
                document.annotations = result.annotations

                // Register with DocumentManager
                DocumentManager.shared.registerDocument(document)

                debugLog("handleDownloadedFileSync: Loaded '\(document.name)' with \(document.sequences.count) sequences, \(document.annotations.count) annotations")

                activityIndicator?.hide()
                viewerController?.displayDocument(document)

                // Refresh sidebar from filesystem - FileSystemWatcher should have detected the new file,
                // but we force a refresh to ensure immediate update
                sidebarController?.reloadFromFilesystem()

                // Select the downloaded file in the sidebar to highlight what's being viewed
                sidebarController?.selectItem(forURL: result.url)

                debugLog("handleDownloadedFileSync: Document displayed and sidebar refreshed")
            }
        }

        debugLog("handleDownloadedFileSync: Background load initiated")
    }

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
            let fileExtension = tempURL.pathExtension
            var baseName = tempURL.deletingPathExtension().lastPathComponent

            // Strip the UID suffix from batch downloads (format: "accession_uid.ext" -> "accession.ext")
            // UIDs are numeric, so we look for _digits at the end of the basename.
            // Skip for .lungfishref bundles — their filenames are already clean accessions
            // and accession numbers like NC_045512 contain underscore+digits that would be
            // incorrectly stripped.
            if fileExtension != "lungfishref",
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
                try? FileManager.default.removeItem(at: tempURL)
                copiedURLs.append(destinationURL)
            } catch {
                debugLog("handleMultipleDownloadsSync: Failed to copy \(originalFilename) - \(error)")
            }
        }

        // Now load the first file to display (load others in background)
        if let firstURL = copiedURLs.first {
            if firstURL.pathExtension.lowercased() == "lungfishref" {
                activityIndicator?.hide()
                refreshSidebarAndSelectImportedURL(firstURL)
                debugLog("handleMultipleDownloadsSync: Imported \(copiedURLs.count) bundle(s)")
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
                    }

                    debugLog("handleMultipleDownloadsSync: Completed importing \(copiedURLs.count) files")
                }
            }
        } else {
            activityIndicator?.hide()
            sidebarController?.reloadFromFilesystem()
        }
    }

    /// Handles a downloaded file by copying it to a persistent location and adding to the sidebar.
    ///
    /// This method:
    /// 1. Copies the file from temp directory to user's Downloads folder (or project directory if available)
    /// 2. Loads the document via DocumentManager (which posts notification to update sidebar)
    /// 3. Displays the document in the viewer
    ///
    /// - Parameter tempFileURL: The URL of the downloaded file in the temp directory
    private func handleDownloadedFile(at tempFileURL: URL) {
        debugLog("handleDownloadedFile: Starting with \(tempFileURL.path)")

        // Determine destination: use project directory, working directory, or Downloads folder
        let destinationDirectory: URL
        if let projectURL = DocumentManager.shared.activeProject?.url {
            // Save to project's "downloads" subdirectory
            destinationDirectory = projectURL.appendingPathComponent("Downloads", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            // Save to working directory's "downloads" subdirectory
            destinationDirectory = workingURL.appendingPathComponent("Downloads", isDirectory: true)
        } else {
            // Fall back to user's Downloads folder with a Lungfish subdirectory
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Create destination directory if needed
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("Warning: Could not create destination directory: \(error.localizedDescription)")
            // Fall back to opening from temp location
            _ = openDocument(at: tempFileURL)
            return
        }

        // Generate unique filename if file already exists
        let originalFilename = tempFileURL.lastPathComponent
        var destinationURL = destinationDirectory.appendingPathComponent(originalFilename)
        var counter = 1
        let fileExtension = tempFileURL.pathExtension
        let baseName = tempFileURL.deletingPathExtension().lastPathComponent

        while FileManager.default.fileExists(atPath: destinationURL.path) {
            let newFilename = "\(baseName)_\(counter).\(fileExtension)"
            destinationURL = destinationDirectory.appendingPathComponent(newFilename)
            counter += 1
        }

        // Copy file to persistent location
        do {
            try FileManager.default.copyItem(at: tempFileURL, to: destinationURL)
            debugLog("handleDownloadedFile: Copied file to \(destinationURL.path)")

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempFileURL)
        } catch {
            debugLog("handleDownloadedFile: Copy failed - \(error.localizedDescription)")
            // Fall back to opening from temp location
            _ = openDocument(at: tempFileURL)
            return
        }

        debugLog("handleDownloadedFile: Scheduling loadDownloadedFile via DispatchQueue")

        // Load the document from its new permanent location using DispatchQueue
        // which properly supports Swift concurrency Task scheduling
        // Use strong self capture since we need AppDelegate to stay alive
        let selfRef = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            debugLog("handleDownloadedFile: DispatchQueue block executing")
            selfRef.loadDownloadedFile(at: destinationURL)
        }
        debugLog("handleDownloadedFile: DispatchQueue scheduled")
    }

    /// Loads a downloaded file and displays it in the viewer.
    ///
    /// Uses the same async/await pattern that works reliably elsewhere in the app.
    private func loadDownloadedFile(at url: URL) {
        debugLog("loadDownloadedFile: Loading \(url.path)")

        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        debugLog("loadDownloadedFile: viewerController=\(viewerController != nil), sidebarController=\(sidebarController != nil)")

        viewerController?.showProgress("Loading \(url.lastPathComponent)...")

        // Use regular Task - this works because we're called from DispatchQueue.main.asyncAfter
        // which properly integrates with Swift concurrency
        Task {
            debugLog("loadDownloadedFile Task: Starting async load")
            do {
                let document = try await DocumentManager.shared.loadDocument(at: url)
                debugLog("loadDownloadedFile Task: Loaded document '\(document.name)' with \(document.sequences.count) sequences")

                viewerController?.hideProgress()
                viewerController?.displayDocument(document)

                // With filesystem-backed sidebar: if file is inside project, watcher handles refresh
                // Otherwise add to "Open Documents" section
                if let projectURL = sidebarController?.currentProjectURL {
                    let docPath = document.url.standardizedFileURL.path
                    let projectPath = projectURL.standardizedFileURL.path
                    if !docPath.hasPrefix(projectPath) {
                        // File is outside project - add to sidebar
                        sidebarController?.addLoadedDocument(document)
                    }
                    // Else: File is inside project, FileSystemWatcher handles it
                } else {
                    // No project open - add to sidebar
                    sidebarController?.addLoadedDocument(document)
                }
                debugLog("loadDownloadedFile Task: Document displayed and added to sidebar")
            } catch {
                debugLog("loadDownloadedFile Task: Load failed with error: \(error)")
                viewerController?.hideProgress()

                let alert = NSAlert()
                alert.messageText = "Failed to Load Downloaded File"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
        debugLog("loadDownloadedFile: Task created")
    }

    @objc func runNextflow(_ sender: Any?) {
        showNotImplementedAlert("Nextflow Runner")
    }

    @objc func runSnakemake(_ sender: Any?) {
        showNotImplementedAlert("Snakemake Runner")
    }

    @objc func openWorkflowBuilder(_ sender: Any?) {
        showNotImplementedAlert("Workflow Builder")
    }

    private func showNotImplementedAlert(_ feature: String) {
        let alert = NSAlert()
        alert.messageText = "Feature Not Yet Implemented"
        alert.informativeText = "\(feature) will be available in a future release."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - HelpMenuActions

    @objc func openDocumentation(_ sender: Any?) {
        if let url = URL(string: "https://github.com/dho/lungfish-genome-browser#readme") {
            NSWorkspace.shared.open(url)
        }
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
