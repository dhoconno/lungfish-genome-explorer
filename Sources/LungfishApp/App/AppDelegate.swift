// AppDelegate.swift - Application lifecycle management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers

/// Debug logging to file for troubleshooting
private func debugLog(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let threadInfo = Thread.isMainThread ? "main" : "bg"
    let logMessage = "[\(timestamp)][\(threadInfo)] \(message)\n"
    print("[\(threadInfo)] \(message)")  // Also print to console
    if let data = logMessage.data(using: .utf8) {
        let logURL = URL(fileURLWithPath: "/tmp/lungfish-debug.log")
        if let fileHandle = try? FileHandle(forWritingTo: logURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        }
    }
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
    debugLog("scheduleOnMainRunLoop: Scheduling block via CFRunLoopPerformBlock")

    // Use CFRunLoopPerformBlock directly - this bypasses GCD completely
    // and schedules the block directly to the main run loop
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
        debugLog("scheduleOnMainRunLoop: CFRunLoopPerformBlock executing")
        // We're on main thread via CFRunLoop, safe to assume MainActor
        MainActor.assumeIsolated {
            debugLog("scheduleOnMainRunLoop: MainActor block executing")
            block()
        }
    }
    // Wake up the run loop to process the block immediately
    CFRunLoopWakeUp(CFRunLoopGetMain())
    debugLog("scheduleOnMainRunLoop: CFRunLoopWakeUp called")
}

/// Result of loading file data on a background thread.
/// This struct contains only Sendable data that can be safely passed between threads.
private struct FileLoadResult: Sendable {
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
private func loadFileInBackground(at url: URL, completion: @escaping @Sendable (FileLoadResult) -> Void) {
    debugLog("loadFileInBackground: Starting for \(url.path)")

    DispatchQueue.global(qos: .userInitiated).async {
        debugLog("loadFileInBackground: Background thread starting")

        // Detect document type
        guard let type = DocumentType.detect(from: url) else {
            debugLog("loadFileInBackground: Unsupported format \(url.pathExtension)")
            completion(FileLoadResult(url: url, type: .fasta, error: "Unsupported file format: \(url.pathExtension)"))
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
                completion(FileLoadResult(url: url, type: type, error: "Format not supported for this operation"))
                return
            }

            debugLog("loadFileInBackground: Success - sequences=\(sequences.count), annotations=\(annotations.count)")
            completion(FileLoadResult(url: url, type: type, sequences: sequences, annotations: annotations))

        } catch {
            debugLog("loadFileInBackground: Error - \(error.localizedDescription)")
            completion(FileLoadResult(url: url, type: type, error: error.localizedDescription))
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

    /// Current working directory for downloads when no project is active
    private var workingDirectoryURL: URL?

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
        // Configure application appearance
        configureAppearance()

        // Register for system notifications
        registerNotifications()

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

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil

        // Add the project folder to sidebar immediately for visibility
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController
        sidebarController?.addProjectFolder(projectURL, documents: [])

        // Load the project/folder contents after a short delay
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.loadProjectFolderSync(projectURL)
        }
    }

    private func showMainWindowWithoutProject() {
        // Create and show the main window without a project
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Close welcome window if open
        welcomeWindowController?.close()
        welcomeWindowController = nil
    }

    /// Synchronous wrapper for testing - kicks off async loading
    /// Note: This uses CFRunLoopRun to process Swift concurrency tasks
    private func loadProjectFolderSync(_ url: URL) {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        viewerController?.showProgress("Loading project folder...")

        // Since DocumentManager is @MainActor, we need to stay on main thread
        // Use a completion handler pattern instead of blocking
        loadProjectFolderAsync(url) { [weak self] documents, error in
            viewerController?.hideProgress()

            if let error = error {
                let alert = NSAlert()
                alert.messageText = "Failed to Load Project"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else if let documents = documents, !documents.isEmpty {
                sidebarController?.addProjectFolder(url, documents: documents)

                if let firstDoc = documents.first {
                    viewerController?.displayDocument(firstDoc)
                }
            }
        }
    }

    /// Async loading with completion handler - stores context for selector-based callback
    private var pendingFolderLoadURL: URL?
    private var pendingFolderLoadCompletion: (([LoadedDocument]?, Error?) -> Void)?

    private func loadProjectFolderAsync(_ url: URL, completion: @escaping ([LoadedDocument]?, Error?) -> Void) {
        // Store for use in selector callback
        pendingFolderLoadURL = url
        pendingFolderLoadCompletion = completion

        // Use performSelector with run loop integration
        self.perform(#selector(executePendingFolderLoad), with: nil, afterDelay: 0.1)
    }

    @objc private func executePendingFolderLoad() {
        guard let url = pendingFolderLoadURL,
              let completion = pendingFolderLoadCompletion else {
            return
        }

        // Clear pending state
        pendingFolderLoadURL = nil
        pendingFolderLoadCompletion = nil

        // Load files synchronously to avoid async/await issues in test mode
        var loadedDocuments: [LoadedDocument] = []

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            completion(nil, DocumentLoadError.accessDenied(url))
            return
        }

        for case let fileURL as URL in enumerator {
            guard let type = DocumentType.detect(from: fileURL) else { continue }

            // Handle FASTA and GenBank files synchronously
            if type == .fasta || type == .genbank {
                do {
                    let document = LoadedDocument(url: fileURL, type: type)

                    // Read sequences synchronously using a semaphore
                    let semaphore = DispatchSemaphore(value: 0)
                    var sequences: [Sequence] = []
                    var annotations: [SequenceAnnotation] = []
                    var readError: Error?

                    // Run in a background thread so we can wait
                    DispatchQueue.global().async {
                        let group = DispatchGroup()
                        group.enter()

                        Task {
                            do {
                                if type == .fasta {
                                    let reader = try FASTAReader(url: fileURL)
                                    sequences = try await reader.readAll()
                                } else if type == .genbank {
                                    let reader = try GenBankReader(url: fileURL)
                                    let records = try await reader.readAll()
                                    for record in records {
                                        sequences.append(record.sequence)
                                        annotations.append(contentsOf: record.annotations)
                                    }
                                }
                            } catch {
                                readError = error
                            }
                            group.leave()
                        }

                        group.wait()
                        semaphore.signal()
                    }

                    semaphore.wait()

                    if readError != nil {
                        continue
                    }

                    document.sequences = sequences
                    document.annotations = annotations
                    loadedDocuments.append(document)

                    // Register with DocumentManager so sidebar selection can find it
                    DocumentManager.shared.registerDocument(document)
                }
            }
        }

        completion(loadedDocuments, nil)
    }

    /// Internal method for testing - loads a project folder without dialog
    private func loadProjectFolderForTesting(_ url: URL) async {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        viewerController?.showProgress("Loading project folder...")

        do {
            let documents = try await DocumentManager.shared.loadProjectFolder(at: url)

            viewerController?.hideProgress()

            if !documents.isEmpty {
                sidebarController?.addProjectFolder(url, documents: documents)

                if let firstDoc = documents.first {
                    viewerController?.displayDocument(firstDoc)
                }
            }
        } catch {
            viewerController?.hideProgress()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Save application state
        saveApplicationState()
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
    }

    /// Handles annotation updates from the inspector.
    @objc private func handleAnnotationUpdated(_ notification: Notification) {
        guard let annotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation else {
            return
        }

        // Update the annotation in the current document
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        guard let document = viewerController?.currentDocument else { return }

        // Find and replace the annotation in the document
        if let index = document.annotations.firstIndex(where: { $0.id == annotation.id }) {
            document.annotations[index] = annotation
            // Refresh the viewer to show updated annotation
            viewerController?.viewerView.setAnnotations(document.annotations)
            viewerController?.viewerView.needsDisplay = true
        }
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
                print("Loaded document: \(document.name) with \(document.sequences.count) sequences")

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

            // Use the synchronous loading approach (same as --test-folder)
            self.loadProjectFolderSync(url)
        }
    }

    @IBAction func showPreferences(_ sender: Any?) {
        // Show preferences window (will be SwiftUI Settings scene)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: - FileMenuActions

    @objc func importFASTA(_ sender: Any?) {
        showImportPanel(
            title: "Import FASTA Sequences",
            types: [
                UTType(filenameExtension: "fa")!,
                UTType(filenameExtension: "fasta")!,
                UTType(filenameExtension: "fna")!,
            ]
        )
    }

    @objc func importFASTQ(_ sender: Any?) {
        showImportPanel(
            title: "Import FASTQ Reads",
            types: [
                UTType(filenameExtension: "fq")!,
                UTType(filenameExtension: "fastq")!,
            ]
        )
    }

    @objc func importGenBank(_ sender: Any?) {
        showImportPanel(
            title: "Import GenBank File",
            types: [
                UTType(filenameExtension: "gb")!,
                UTType(filenameExtension: "gbk")!,
            ]
        )
    }

    @objc func importGFF3(_ sender: Any?) {
        showImportPanel(
            title: "Import GFF3 Annotations",
            types: [
                UTType(filenameExtension: "gff")!,
                UTType(filenameExtension: "gff3")!,
            ]
        )
    }

    @objc func importBED(_ sender: Any?) {
        showImportPanel(
            title: "Import BED Annotations",
            types: [
                UTType(filenameExtension: "bed")!,
            ]
        )
    }

    @objc func importBAM(_ sender: Any?) {
        showImportPanel(
            title: "Import BAM/CRAM Alignments",
            types: [
                UTType(filenameExtension: "bam")!,
                UTType(filenameExtension: "cram")!,
            ]
        )
    }

    @objc func exportFASTA(_ sender: Any?) {
        showExportPanel(title: "Export FASTA", defaultExtension: "fa")
    }

    @objc func exportGenBank(_ sender: Any?) {
        showExportPanel(title: "Export GenBank", defaultExtension: "gb")
    }

    @objc func exportGFF3(_ sender: Any?) {
        showExportPanel(title: "Export GFF3", defaultExtension: "gff3")
    }

    @objc func exportImage(_ sender: Any?) {
        showExportPanel(title: "Export Image", defaultExtension: "png")
    }

    @objc func exportPDF(_ sender: Any?) {
        showExportPanel(title: "Export PDF", defaultExtension: "pdf")
    }

    private func showImportPanel(title: String, types: [UTType]) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types

        panel.begin { response in
            if response == .OK {
                for url in panel.urls {
                    _ = self.openDocument(at: url)
                }
            }
        }
    }

    private func showExportPanel(title: String, defaultExtension: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.allowedContentTypes = [UTType(filenameExtension: defaultExtension)!]
        panel.nameFieldStringValue = "untitled.\(defaultExtension)"

        panel.begin { response in
            if response == .OK, let url = panel.url {
                print("Export to: \(url.path)")
                // TODO: Implement export
            }
        }
    }

    // MARK: - ViewMenuActions

    @objc func toggleSidebar(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.toggleSidebar()
    }

    @objc func toggleInspector(_ sender: Any?) {
        mainWindowController?.mainSplitViewController?.toggleInspector()
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

    // MARK: - Menu Validation

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Update Inspector menu item title based on state
        if menuItem.tag == 1001 {
            if let isInspectorVisible = mainWindowController?.mainSplitViewController?.isInspectorVisible {
                menuItem.title = isInspectorVisible ? "Hide Inspector" : "Show Inspector"
            }
            return true
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
        // Show go-to-position dialog
        let alert = NSAlert()
        alert.messageText = "Go to Position"
        alert.informativeText = "Enter a genomic position or region:"
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        textField.placeholderString = "chr1:1000000 or chr1:1000000-2000000"
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let input = textField.stringValue
            print("Navigate to: \(input)")
            // TODO: Parse position and navigate
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

                print("Added annotation: \(name) (\(typeString)) at \(selectionRange)")
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
        showNotImplementedAlert("SPAdes Assembly")
    }

    @objc func runMEGAHIT(_ sender: Any?) {
        showNotImplementedAlert("MEGAHIT Assembly")
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

    /// Shows the database browser for the specified source.
    private func showDatabaseBrowser(source: DatabaseSource) {
        guard let window = mainWindowController?.window else { return }

        let browserController = DatabaseBrowserViewController(source: source)

        // Handle single download completion (legacy callback)
        browserController.onDownloadComplete = { [weak self] tempFileURL in
            debugLog("onDownloadComplete: Received file \(tempFileURL.path)")

            // Store the URL first, before dismissing the sheet
            self?.pendingDownloadTempURL = tempFileURL
            debugLog("onDownloadComplete: Stored pending URL")

            // Dismiss the sheet - the completion handler will process the download
            if let sheet = window.attachedSheet {
                debugLog("onDownloadComplete: Ending sheet")
                window.endSheet(sheet)
            }
        }

        // Handle multiple downloads completion (batch download)
        browserController.onMultipleDownloadsComplete = { [weak self] tempFileURLs in
            debugLog("onMultipleDownloadsComplete: Received \(tempFileURLs.count) files")

            // Store the URLs first, before dismissing the sheet
            self?.pendingDownloadTempURLs = tempFileURLs
            debugLog("onMultipleDownloadsComplete: Stored \(tempFileURLs.count) pending URLs")

            // Dismiss the sheet - the completion handler will process the downloads
            if let sheet = window.attachedSheet {
                debugLog("onMultipleDownloadsComplete: Ending sheet")
                window.endSheet(sheet)
            }
        }

        // Present as sheet
        let browserWindow = NSWindow(contentViewController: browserController)
        browserWindow.title = "Search \(source.displayName)"

        window.beginSheet(browserWindow) { [weak self] _ in
            debugLog("Sheet dismissed callback executing")
            // Sheet is now fully dismissed - safe to process the downloads

            // Check for multiple downloads first
            if let tempURLs = self?.pendingDownloadTempURLs, !tempURLs.isEmpty {
                self?.pendingDownloadTempURLs = nil
                debugLog("Sheet dismissed: Processing \(tempURLs.count) pending downloads")
                for tempURL in tempURLs {
                    self?.handleDownloadedFileSync(at: tempURL)
                }
            } else if let tempURL = self?.pendingDownloadTempURL {
                // Fall back to single download
                self?.pendingDownloadTempURL = nil
                debugLog("Sheet dismissed: Processing pending download \(tempURL.path)")
                self?.handleDownloadedFileSync(at: tempURL)
            } else {
                debugLog("Sheet dismissed: No pending URLs")
            }
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

        // Determine destination
        let destinationDirectory: URL
        if let projectURL = DocumentManager.shared.activeProject?.url {
            destinationDirectory = projectURL.appendingPathComponent("downloads", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            destinationDirectory = workingURL.appendingPathComponent("downloads", isDirectory: true)
        } else {
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Create destination directory
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            debugLog("handleDownloadedFileSync: Failed to create directory - \(error)")
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
            _ = openDocument(at: tempFileURL)
            return
        }

        // Get UI controllers (we're still on MainActor here)
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        debugLog("handleDownloadedFileSync: viewerController=\(viewerController != nil), sidebarController=\(sidebarController != nil)")

        viewerController?.showProgress("Loading \(destinationURL.lastPathComponent)...")

        debugLog("handleDownloadedFileSync: Starting background file load")

        // Load file data entirely on a background thread using GCD (no Swift concurrency).
        // This avoids the blocked MainActor issue completely.
        loadFileInBackground(at: destinationURL) { result in
            debugLog("handleDownloadedFileSync: Background load completed with result")

            // Now update UI on MainActor using Timer-based scheduling
            scheduleOnMainRunLoop { [weak viewerController, weak sidebarController] in
                debugLog("handleDownloadedFileSync: scheduleOnMainRunLoop block executing")

                if let errorMessage = result.error {
                    debugLog("handleDownloadedFileSync: Error - \(errorMessage)")
                    viewerController?.hideProgress()

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

                viewerController?.hideProgress()
                viewerController?.displayDocument(document)

                // Get the project URL to place the document in the correct downloads folder
                let projectURL = DocumentManager.shared.activeProject?.url ?? AppDelegate.shared?.getWorkingDirectoryURL()
                sidebarController?.addDownloadedDocument(document, projectURL: projectURL)

                debugLog("handleDownloadedFileSync: Document displayed and added to sidebar")
            }
        }

        debugLog("handleDownloadedFileSync: Background load initiated")
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
            destinationDirectory = projectURL.appendingPathComponent("downloads", isDirectory: true)
        } else if let workingURL = workingDirectoryURL {
            // Save to working directory's "downloads" subdirectory
            destinationDirectory = workingURL.appendingPathComponent("downloads", isDirectory: true)
        } else {
            // Fall back to user's Downloads folder with a Lungfish subdirectory
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            destinationDirectory = downloadsURL.appendingPathComponent("Lungfish Downloads", isDirectory: true)
        }

        // Create destination directory if needed
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            print("Warning: Could not create destination directory: \(error.localizedDescription)")
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
                sidebarController?.addLoadedDocument(document)
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
