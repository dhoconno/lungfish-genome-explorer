// AppDelegate+ImportExport.swift - App delegate import/export actions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishPhylogeneticsUI
import LungfishWorkflow
import SQLite3
import os

extension AppDelegate {
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
        let current = currentProvenanceExportReading()
        switch current.resolution {
        case .resolved(let source):
            presentProvenanceExportSheet(source: source, shape: current.shape ?? .envelope, format: format)
            return
        case .unresolvedSelection:
            showNoProvenanceAlert()
            return
        case .noCurrentSource:
            break
        }

        Task {
            // The latest completed run the recorder still holds, as the record its save writes.
            let envelopes = await ProvenanceRecorder.shared.canonicalEnvelopes()
            guard let envelope = envelopes.first(where: { $0.status == .completed }) else {
                self.showNoProvenanceAlert()
                return
            }
            let sidecarURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-provenance-export-\(envelope.id.uuidString)")
                .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            do {
                try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
                self.presentProvenanceExportSheet(
                    source: AppProvenanceExportSource(
                        selectedURL: sidecarURL,
                        sourceSidecarURL: sidecarURL,
                        envelope: envelope
                    ),
                    shape: .envelope,
                    format: format
                )
            } catch {
                self.showFailure(AppFailureReports.prepareProvenanceForExport(error))
            }
        }
    }

    /// What File > Export > Provenance would export now.
    ///
    /// The viewer's candidates are listed in the order the export prefers them. The sidebar
    /// selection decides unless a candidate is the selection or a bundle that contains it,
    /// which `AppProvenanceExportSourceResolver` explains. Internal so a test can ask without
    /// opening the save panel.
    func currentProvenanceExportResolution() -> AppProvenanceExportResolution {
        currentProvenanceExportReading().resolution
    }

    /// The export source with the shape the reader gave its record, from the finder's one walk
    /// (`ProvenanceRecorder.findProvenanceReading(for:)`), so the pin gate can refuse the Older
    /// record format (plan decision V6). The shape is nil when no record was found.
    func currentProvenanceExportReading() -> (
        resolution: AppProvenanceExportResolution, shape: ProvenanceEnvelopeReader.RecordShape?
    ) {
        let splitViewController = mainWindowController?.mainSplitViewController
        let viewerController = splitViewController?.viewerController
        let viewerCandidates: [URL?] = [
            viewerController?.currentFASTQDatasetURL,
            viewerController?.multipleSequenceAlignmentViewController?.bundleURL,
            viewerController?.phylogeneticTreeViewController?.bundleURL,
            viewerController?.referenceBundleViewportController?.currentInput?.mappingResultDirectoryURL,
            viewerController?.mappingResultController?.currentInput?.mappingResultDirectoryURL,
            viewerController?.currentBundleURL,
            viewerController?.referenceBundleViewportController?.currentInput?.renderedBundleURL,
            viewerController?.mappingResultController?.currentInput?.renderedBundleURL,
            viewerController?.currentDocument?.url,
        ]
        var shape: ProvenanceEnvelopeReader.RecordShape?
        let resolution = AppProvenanceExportSourceResolver.resolve(
            viewerCandidates: viewerCandidates,
            sidebarSelection: splitViewController?.sidebarController?.selectedFileURL,
            findRecord: { url in
                guard let found = ProvenanceRecorder.findProvenanceReading(for: url) else { return nil }
                shape = found.reading.shape
                return (sidecarURL: found.sidecarURL, envelope: found.reading.envelope)
            }
        )
        return (resolution, shape)
    }

    private func presentProvenanceExportSheet(
        source: AppProvenanceExportSource,
        shape: ProvenanceEnvelopeReader.RecordShape,
        format: ProvenanceExportFormat
    ) {
        guard let window = activeMainWindowController()?.window ?? mainWindowController?.window ?? NSApp.keyWindow else {
            return
        }
        let request = ProvenanceExportRequest(
            envelope: source.envelope,
            sourceSidecarURL: source.sourceSidecarURL,
            selectedURL: source.selectedURL,
            shape: shape,
            format: format
        )
        // Plan decision S7. The pin gate's sheet comes before the save panel.
        ProvenanceExportPinGatePresenter.present(request, window: window) { allowUnpinned in
            self.presentProvenanceSavePanel(request, allowUnpinned: allowUnpinned, window: window)
        }
    }

    private func presentProvenanceSavePanel(_ request: ProvenanceExportRequest, allowUnpinned: Bool, window: NSWindow) {
        let savePanel = AppFilePanelFactory.provenanceExportPanel(
            defaultDirectoryName: defaultProvenanceExportDirectoryName(for: request.format, sourceURL: request.selectedURL),
            sourceURL: request.selectedURL
        )
        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let outputDirectory = savePanel.url else { return }
            do {
                let existingIsDirectory = self.existingDirectoryState(outputDirectory)
                if existingIsDirectory == false {
                    throw ProvenanceError.exportFailed(
                        "The selected path exists and is not a folder: \(outputDirectory.path)"
                    )
                }
                // Phase 2.12 lane 12.38, B9. The row runs `lungfish-cli provenance export` and the leaf writes the folder.
                AppDelegate.runProvenanceExport(
                    request: request, allowUnpinned: allowUnpinned, outputDirectory: outputDirectory, window: window
                )
            } catch {
                debugLog("Provenance export refused: \(error)")
                AppDelegate.presentProvenanceExportSummary(
                    AppDelegate.provenanceExportFailureSummary(error.localizedDescription), window: window
                )
            }
        }
    }

    private func defaultProvenanceExportDirectoryName(for format: ProvenanceExportFormat, sourceURL: URL) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let safeBaseName = baseName.isEmpty ? "provenance" : baseName
        return "\(safeBaseName)-provenance-\(format.cliToken)"
    }

    private func existingDirectoryState(_ url: URL) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue
    }

    private func showNoProvenanceAlert() {
        let alert = NSAlert()
        alert.messageText = "No Provenance Available"
        alert.informativeText = "No provenance record was found for the selected file or bundle. Provenance is recorded when files are created through tool operations (assembly, import, conversion, etc.)."
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

        let panel = AppFilePanelFactory.ontRunImportPanel()

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
        let controller = activeMainWindowController(sender: sender)
        guard let sidebarController = controller?.mainSplitViewController?.sidebarController else {
            showExportError(message: "No sidebar available.")
            return
        }

        let rawSelection = sidebarController.selectedItems()
        let exportSelection = SidebarExportSelection(rawSelection, format: .fastq)
        let items = exportSelection.exportable
        guard !items.isEmpty else {
            showExportError(message: "No FASTQ datasets selected. Select one or more FASTQ bundles in the sidebar.")
            return
        }

        guard let window = controller?.window else { return }

        // A mixed selection with SOME exportable items: proceed with the
        // exportable subset, but tell the user exactly what got skipped
        // instead of silently narrowing scope (AS15 / task E4).
        if !exportSelection.skipped.isEmpty {
            let skippedNames = exportSelection.skippedDescriptions.joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Some Selected Items Will Be Skipped"
            alert.informativeText = "\(exportSelection.skipped.count) of \(rawSelection.count) selected item(s) are not FASTQ datasets and will be skipped: \(skippedNames)."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.continueExportFASTQ(items: items, window: window)
            }
            return
        }

        continueExportFASTQ(items: items, window: window)
    }

    /// Continuation of `exportFASTQ(_:)` after the skipped-items
    /// confirmation (if any) has been accepted.
    private func continueExportFASTQ(items: [SidebarItem], window: NSWindow) {
        if items.count == 1 {
            // Single selection: use save panel
            let item = items[0]
            let bundleURL = item.url!
            let isDerived = FASTQBundle.isDerivedBundle(bundleURL)
            let suggestedName = Self.fastqExportSuggestedFilename(bundleURL: bundleURL, isDerived: isDerived)

            let savePanel = AppFilePanelFactory.fastqSingleExportPanel(suggestedName: suggestedName)
            savePanel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let outputURL = savePanel.url else { return }
                self?.performFASTQExports(
                    bundles: [(bundleURL, outputURL, isDerived, item.title)],
                    window: window
                )
            }
        } else {
            // Multi-selection: use open panel (folder picker)
            let openPanel = AppFilePanelFactory.fastqBatchExportFolderPanel(itemCount: items.count)
            openPanel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK, let folderURL = openPanel.url else { return }
                var bundles: [(bundleURL: URL, outputURL: URL, isDerived: Bool, title: String)] = []
                for item in items {
                    let bundleURL = item.url!
                    let isDerived = FASTQBundle.isDerivedBundle(bundleURL)
                    let filename = Self.fastqExportSuggestedFilename(bundleURL: bundleURL, isDerived: isDerived)
                    let outputURL = folderURL.appendingPathComponent(filename)
                    bundles.append((bundleURL, outputURL, isDerived, item.title))
                }
                self?.performFASTQExports(bundles: bundles, window: window)
            }
        }
    }

    /// Exports one or more FASTQ bundles. Each bundle begins an Operations row and runs
    /// `lungfish-cli fastq export reads` on the shared viewer export runner, one after another in the order of the
    /// selection (Phase 2.12 lane 12.38, ARCH ruling 1.5). The alert after the batch keeps the words the in-app
    /// writer showed, and a cancel shows none (UX 4).
    private func performFASTQExports(
        bundles: [(bundleURL: URL, outputURL: URL, isDerived: Bool, title: String)],
        window: NSWindow
    ) {
        let exports = bundles.map {
            FASTQBundleExport(bundleURL: $0.bundleURL, outputURL: $0.outputURL, isDerived: $0.isDerived, title: $0.title)
        }
        Task { @MainActor in
            let results = await AppDelegate.runFASTQBundleExports(exports)
            guard let summary = AppDelegate.fastqExportSummary(for: results) else { return }
            let alert = NSAlert()
            alert.messageText = summary.title
            alert.informativeText = summary.message
            switch summary.style {
            case .informational: alert.alertStyle = .informational
            case .warning: alert.alertStyle = .warning
            case .critical: alert.alertStyle = .critical
            }
            alert.addButton(withTitle: "OK")
            if summary.revealURL != nil {
                alert.addButton(withTitle: "Show in Finder")
            }
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn, let revealURL = summary.revealURL {
                    NSWorkspace.shared.activateFileViewerSelecting([revealURL])
                }
            }
        }
    }

    nonisolated static func fastqExportSuggestedFilename(bundleURL: URL, isDerived: Bool) -> String {
        let baseName = FASTQBundle.deriveBaseName(from: bundleURL)
        if isDerived {
            return baseName + ".fastq.gz"
        }
        if let allFASTQURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), allFASTQURLs.count > 1 {
            let suffix = allFASTQURLs.allSatisfy(\.isGzipCompressed) ? ".fastq.gz" : ".fastq"
            return baseName + suffix
        }
        if let primaryURL = FASTQBundle.resolvePrimaryFASTQURL(for: bundleURL) {
            return primaryURL.lastPathComponent
        }
        return baseName + ".fastq"
    }

    // MARK: - Project-Level Metadata Export/Import

    @objc func exportProjectSampleMetadata(_ sender: Any?) {
        let controller = activeMainWindowController(sender: sender)
        switch ProjectSampleMetadataModalRouter.exportRoute(
            projectURL: projectFolderURLForMetadata(controller: controller)
        ) {
        case .missingProject(let title, let message):
            showAlert(
                title: title,
                message: message,
                presentingWindow: controller?.window
            )
            return
        case .exportSheet(let request):
            let sheet = ProjectSampleMetadataModalRouter.makeExportSheet(for: request)
            guard let window = controller?.window ?? NSApp.keyWindow else { return }
            window.contentViewController?.presentAsSheet(sheet)
        case .importSheet:
            return
        }
    }

    @objc func importProjectSampleMetadata(_ sender: Any?) {
        let controller = activeMainWindowController(sender: sender)
        switch ProjectSampleMetadataModalRouter.importRoute(
            projectURL: projectFolderURLForMetadata(controller: controller),
            windowStateScope: controller?.projectSession.windowStateScope
        ) {
        case .missingProject(let title, let message):
            showAlert(
                title: title,
                message: message,
                presentingWindow: controller?.window
            )
            return
        case .importSheet(let request):
            let sheet = ProjectSampleMetadataModalRouter.makeImportSheet(for: request)
            guard let window = controller?.window ?? NSApp.keyWindow else { return }
            window.contentViewController?.presentAsSheet(sheet)
        case .exportSheet:
            return
        }
    }

    /// Returns the current project folder URL from the sidebar, if available.
    private func projectFolderURLForMetadata(controller: MainWindowController? = nil) -> URL? {
        let controller = controller ?? activeMainWindowController()
        return controller?.mainSplitViewController?.sidebarController?.projectFolderURL
            ?? controller?.projectSession.projectURL
    }
}
