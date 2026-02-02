// AppDelegate.swift - Application lifecycle management
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers

/// Main application delegate handling app lifecycle and global state.
@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate,
    FileMenuActions, ViewMenuActions, SequenceMenuActions, ToolsMenuActions, HelpMenuActions {

    /// The shared application delegate instance
    public static var shared: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// Main window controller for the application
    private var mainWindowController: MainWindowController?

    // MARK: - Application Lifecycle

    public func applicationWillFinishLaunching(_ notification: Notification) {
        // Install the main menu before app finishes launching
        NSApp.mainMenu = MainMenu.createMainMenu()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Create and show the main window
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)

        // Configure application appearance
        configureAppearance()

        // Register for system notifications
        registerNotifications()

        // Check for --test-folder argument for automated testing
        let args = ProcessInfo.processInfo.arguments
        if let folderIndex = args.firstIndex(of: "--test-folder"),
           folderIndex + 1 < args.count {
            let folderPath = args[folderIndex + 1]
            fputs("DEBUG: Auto-loading test folder: \(folderPath)\n", stderr)
            let url = URL(fileURLWithPath: folderPath)

            fputs("DEBUG: Using Timer to schedule folder load\n", stderr)
            // Use a Timer to schedule after the run loop is active
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                fputs("DEBUG: Timer fired\n", stderr)
                guard let self = self else {
                    fputs("DEBUG: self is nil in timer callback\n", stderr)
                    return
                }
                // Call synchronous test method directly (no async/await)
                self.loadProjectFolderSync(url)
            }
        }
    }

    /// Synchronous wrapper for testing - kicks off async loading
    /// Note: This uses CFRunLoopRun to process Swift concurrency tasks
    private func loadProjectFolderSync(_ url: URL) {
        fputs("DEBUG loadProjectFolderSync: Starting for \(url.path)\n", stderr)
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        fputs("DEBUG loadProjectFolderSync: sidebarController = \(sidebarController != nil)\n", stderr)
        fputs("DEBUG loadProjectFolderSync: viewerController = \(viewerController != nil)\n", stderr)

        viewerController?.showProgress("Loading project folder...")

        // Since DocumentManager is @MainActor, we need to stay on main thread
        // Use a completion handler pattern instead of blocking
        loadProjectFolderAsync(url) { [weak self] documents, error in
            fputs("DEBUG loadProjectFolderSync: Completion handler called\n", stderr)
            viewerController?.hideProgress()

            if let error = error {
                fputs("DEBUG loadProjectFolderSync: Error occurred: \(error.localizedDescription)\n", stderr)
                let alert = NSAlert()
                alert.messageText = "Failed to Load Project"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            } else if let documents = documents, !documents.isEmpty {
                fputs("DEBUG loadProjectFolderSync: Adding \(documents.count) docs to sidebar\n", stderr)
                sidebarController?.addProjectFolder(url, documents: documents)

                if let firstDoc = documents.first {
                    fputs("DEBUG loadProjectFolderSync: Displaying first doc: \(firstDoc.name)\n", stderr)
                    viewerController?.displayDocument(firstDoc)
                }
            } else {
                fputs("DEBUG loadProjectFolderSync: No documents found\n", stderr)
            }
        }
        fputs("DEBUG loadProjectFolderSync: Async load initiated\n", stderr)
    }

    /// Async loading with completion handler - stores context for selector-based callback
    private var pendingFolderLoadURL: URL?
    private var pendingFolderLoadCompletion: (([LoadedDocument]?, Error?) -> Void)?

    private func loadProjectFolderAsync(_ url: URL, completion: @escaping ([LoadedDocument]?, Error?) -> Void) {
        fputs("DEBUG loadProjectFolderAsync: Creating task for \(url.path)\n", stderr)

        // Store for use in selector callback
        pendingFolderLoadURL = url
        pendingFolderLoadCompletion = completion

        // Use performSelector with run loop integration
        fputs("DEBUG loadProjectFolderAsync: Scheduling performSelector\n", stderr)
        self.perform(#selector(executePendingFolderLoad), with: nil, afterDelay: 0.1)
    }

    @objc private func executePendingFolderLoad() {
        fputs("DEBUG executePendingFolderLoad: Selector callback fired\n", stderr)

        guard let url = pendingFolderLoadURL,
              let completion = pendingFolderLoadCompletion else {
            fputs("DEBUG executePendingFolderLoad: Missing URL or completion\n", stderr)
            return
        }

        // Clear pending state
        pendingFolderLoadURL = nil
        pendingFolderLoadCompletion = nil

        fputs("DEBUG executePendingFolderLoad: Loading files synchronously\n", stderr)

        // Load files synchronously to avoid async/await issues in test mode
        var loadedDocuments: [LoadedDocument] = []

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            fputs("DEBUG executePendingFolderLoad: Failed to create enumerator\n", stderr)
            completion(nil, DocumentLoadError.accessDenied(url))
            return
        }

        for case let fileURL as URL in enumerator {
            guard let type = DocumentType.detect(from: fileURL) else { continue }

            fputs("DEBUG executePendingFolderLoad: Found file: \(fileURL.lastPathComponent) type=\(type.rawValue)\n", stderr)

            // Only handle FASTA for now in sync mode
            if type == .fasta {
                do {
                    let document = LoadedDocument(url: fileURL, type: type)
                    let reader = try FASTAReader(url: fileURL)

                    // Read sequences synchronously using a semaphore
                    let semaphore = DispatchSemaphore(value: 0)
                    var sequences: [Sequence] = []
                    var readError: Error?

                    // Run in a background thread so we can wait
                    DispatchQueue.global().async {
                        let group = DispatchGroup()
                        group.enter()

                        Task {
                            do {
                                sequences = try await reader.readAll()
                            } catch {
                                readError = error
                            }
                            group.leave()
                        }

                        group.wait()
                        semaphore.signal()
                    }

                    semaphore.wait()

                    if let error = readError {
                        fputs("DEBUG executePendingFolderLoad: Error reading \(fileURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
                        continue
                    }

                    fputs("DEBUG executePendingFolderLoad: Read \(sequences.count) sequences from \(fileURL.lastPathComponent)\n", stderr)
                    document.sequences = sequences
                    loadedDocuments.append(document)

                    // Register with DocumentManager so sidebar selection can find it
                    DocumentManager.shared.registerDocument(document)
                } catch {
                    fputs("DEBUG executePendingFolderLoad: Error loading \(fileURL.lastPathComponent): \(error.localizedDescription)\n", stderr)
                }
            }
        }

        fputs("DEBUG executePendingFolderLoad: Total loaded: \(loadedDocuments.count) documents\n", stderr)
        completion(loadedDocuments, nil)
    }

    /// Internal method for testing - loads a project folder without dialog
    private func loadProjectFolderForTesting(_ url: URL) async {
        let viewerController = mainWindowController?.mainSplitViewController?.viewerController
        let sidebarController = mainWindowController?.mainSplitViewController?.sidebarController

        fputs("DEBUG loadProjectFolderForTesting: mainWindowController = \(mainWindowController != nil)\n", stderr)
        fputs("DEBUG loadProjectFolderForTesting: mainSplitViewController = \(mainWindowController?.mainSplitViewController != nil)\n", stderr)
        fputs("DEBUG loadProjectFolderForTesting: sidebarController = \(sidebarController != nil)\n", stderr)
        fputs("DEBUG loadProjectFolderForTesting: viewerController = \(viewerController != nil)\n", stderr)

        viewerController?.showProgress("Loading project folder...")

        do {
            let documents = try await DocumentManager.shared.loadProjectFolder(at: url)

            viewerController?.hideProgress()

            fputs("DEBUG loadProjectFolderForTesting: Loaded \(documents.count) documents\n", stderr)
            for doc in documents {
                fputs("DEBUG loadProjectFolderForTesting:   - \(doc.name) (\(doc.sequences.count) sequences)\n", stderr)
            }

            if !documents.isEmpty {
                fputs("DEBUG loadProjectFolderForTesting: Calling sidebarController.addProjectFolder\n", stderr)
                sidebarController?.addProjectFolder(url, documents: documents)

                if let firstDoc = documents.first {
                    fputs("DEBUG loadProjectFolderForTesting: Displaying first document\n", stderr)
                    viewerController?.displayDocument(firstDoc)
                }
            }
        } catch {
            viewerController?.hideProgress()
            fputs("DEBUG loadProjectFolderForTesting: ERROR - \(error.localizedDescription)\n", stderr)
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

            fputs("DEBUG openProjectFolder: Selected folder: \(url.path)\n", stderr)

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

    @objc func searchENA(_ sender: Any?) {
        showDatabaseBrowser(source: .ena)
    }

    /// Shows the database browser for the specified source.
    private func showDatabaseBrowser(source: DatabaseSource) {
        guard let window = mainWindowController?.window else { return }

        let browserController = DatabaseBrowserViewController(source: source)

        // Handle download completion
        browserController.onDownloadComplete = { [weak self] fileURL in
            // Dismiss the sheet first
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }

            // Load the downloaded file into the viewer
            _ = self?.openDocument(at: fileURL)
        }

        // Present as sheet
        let browserWindow = NSWindow(contentViewController: browserController)
        browserWindow.title = "Search \(source.displayName)"

        window.beginSheet(browserWindow) { _ in
            // Sheet dismissed
        }
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
