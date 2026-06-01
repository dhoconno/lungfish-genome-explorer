// AppDelegate+ImportExport.swift - Extracted from AppDelegate.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
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

    private struct AppProvenanceExportSource {
        let selectedURL: URL
        let sourceSidecarURL: URL
        let envelope: ProvenanceEnvelope
    }

    private enum AppProvenanceExportResolution {
        case resolved(AppProvenanceExportSource)
        case unresolvedSelection(URL)
        case noCurrentSource
    }

    private func exportProvenance(format: ProvenanceExportFormat) {
        switch currentProvenanceExportResolution() {
        case .resolved(let source):
            presentProvenanceExportSheet(source: source, format: format)
            return
        case .unresolvedSelection:
            showNoProvenanceAlert()
            return
        case .noCurrentSource:
            break
        }

        Task {
            let runs = await ProvenanceRecorder.shared.allRuns()
            guard let completedRun = runs.first(where: { $0.status == .completed }) else {
                self.showNoProvenanceAlert()
                return
            }
            let envelope = completedRun.canonicalEnvelope()
            let sidecarURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-provenance-export-\(completedRun.id.uuidString)")
                .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            do {
                try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
                self.presentProvenanceExportSheet(
                    source: AppProvenanceExportSource(
                        selectedURL: sidecarURL,
                        sourceSidecarURL: sidecarURL,
                        envelope: envelope
                    ),
                    format: format
                )
            } catch {
                self.showExportError(message: "Could not prepare provenance for export: \(error.localizedDescription)")
            }
        }
    }

    private func currentProvenanceExportResolution() -> AppProvenanceExportResolution {
        let splitViewController = mainWindowController?.mainSplitViewController
        let sidebarController = splitViewController?.sidebarController
        let viewerController = splitViewController?.viewerController
        let visibleCandidates = [
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

        var seen = Set<String>()
        var firstVisibleCandidate: URL?
        for candidate in visibleCandidates.compactMap(\.self) {
            let standardized = candidate.standardizedFileURL
            guard seen.insert(standardized.path).inserted else {
                continue
            }
            if firstVisibleCandidate == nil {
                firstVisibleCandidate = standardized
            }
            _ = MetagenomicsBatchProvenanceWriter.ensureEsVirituBatchProvenanceIfPossible(batchRoot: standardized)
            _ = MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: standardized)
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: standardized) {
                return .resolved(
                    AppProvenanceExportSource(
                        selectedURL: standardized,
                        sourceSidecarURL: resolved.sidecarURL,
                        envelope: resolved.envelope
                    )
                )
            }
            return .unresolvedSelection(standardized)
        }
        if let firstVisibleCandidate {
            return .unresolvedSelection(firstVisibleCandidate)
        }

        if let sidebarSelection = sidebarController?.selectedFileURL?.standardizedFileURL,
           seen.insert(sidebarSelection.path).inserted {
            _ = MetagenomicsBatchProvenanceWriter.ensureEsVirituBatchProvenanceIfPossible(batchRoot: sidebarSelection)
            _ = MetagenomicsBatchProvenanceWriter.ensureTaxTriageProvenanceIfPossible(resultDirectory: sidebarSelection)
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: sidebarSelection) {
                return .resolved(
                    AppProvenanceExportSource(
                        selectedURL: sidebarSelection,
                        sourceSidecarURL: resolved.sidecarURL,
                        envelope: resolved.envelope
                    )
                )
            }
            return .unresolvedSelection(sidebarSelection)
        }
        return .noCurrentSource
    }

    private func presentProvenanceExportSheet(source: AppProvenanceExportSource, format: ProvenanceExportFormat) {
        let savePanel = AppFilePanelFactory.provenanceExportPanel(
            defaultDirectoryName: defaultProvenanceExportDirectoryName(for: format, sourceURL: source.selectedURL)
        )

        guard let window = mainWindowController?.window ?? NSApp.keyWindow else {
            return
        }

        savePanel.beginSheetModal(for: window) { response in
            guard response == .OK, let outputDirectory = savePanel.url else { return }
            do {
                let existingIsDirectory = self.existingDirectoryState(outputDirectory)
                if existingIsDirectory == false {
                    throw ProvenanceError.exportFailed(
                        "The selected path exists and is not a folder: \(outputDirectory.path)"
                    )
                }
                let bundle = try ProvenanceExporter().exportBundle(
                    source.envelope,
                    format: format,
                    to: outputDirectory,
                    sourceSidecarURL: source.sourceSidecarURL,
                    sourceRootURL: source.selectedURL,
                    exportArgv: self.guiExportArgv(format: format, sourceURL: source.selectedURL, outputDirectory: outputDirectory)
                )
                debugLog("Provenance exported to \(bundle.primaryArtifactURL.path)")
                self.showProvenanceExportCompleteAlert(bundle: bundle, format: format, window: window)
            } catch {
                debugLog("Provenance export write failed: \(error)")
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.beginSheetModal(for: window)
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

    private func guiExportArgv(
        format: ProvenanceExportFormat,
        sourceURL: URL,
        outputDirectory: URL
    ) -> [String] {
        AppProvenanceExportCommandBuilder.argv(
            format: format,
            sourceURL: sourceURL,
            outputDirectory: outputDirectory
        )
    }

    private func showProvenanceExportCompleteAlert(
        bundle: ProvenanceExportBundle,
        format: ProvenanceExportFormat,
        window: NSWindow
    ) {
        let alert = NSAlert()
        alert.messageText = "Provenance Export Complete"
        alert.informativeText = "\(format.rawValue) exported to \(bundle.primaryArtifactURL.lastPathComponent)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([bundle.primaryArtifactURL])
            }
        }
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
                    try await Self.exportFASTQBundleForSidebar(
                        bundleURL: bundleURL,
                        outputURL: outputURL,
                        isDerived: isDerived,
                        progress: { message in
                            debugLog("Export FASTQ (\(title)): \(message)")
                        }
                    )
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

    nonisolated static func exportFASTQBundleForSidebar(
        bundleURL: URL,
        outputURL: URL,
        isDerived: Bool,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let startedAt = Date()
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try removeExistingItemIfNeeded(at: outputURL)

        if isDerived {
            try await FASTQDerivativeService.shared.exportMaterializedFASTQ(
                fromDerivedBundle: bundleURL,
                to: outputURL,
                progress: progress
            )
            try writeFASTQExportProvenance(
                sourceBundleURL: bundleURL,
                inputFASTQURLs: [],
                outputURL: outputURL,
                isDerived: true,
                startedAt: startedAt
            )
            return
        }

        guard let fastqURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !fastqURLs.isEmpty else {
            throw NSError(domain: "com.lungfish.browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No FASTQ file found inside bundle"])
        }

        if fastqURLs.count == 1 {
            progress?("Copying \(fastqURLs[0].lastPathComponent)...")
            try FileManager.default.copyItem(at: fastqURLs[0], to: outputURL)
            progress?("Export complete: \(outputURL.lastPathComponent)")
            try writeFASTQExportProvenance(
                sourceBundleURL: bundleURL,
                inputFASTQURLs: fastqURLs,
                outputURL: outputURL,
                isDerived: false,
                startedAt: startedAt
            )
            return
        }

        progress?("Exporting \(fastqURLs.count) FASTQ chunks...")
        try await concatenateFASTQChunks(fastqURLs, to: outputURL)
        progress?("Export complete: \(outputURL.lastPathComponent)")
        try writeFASTQExportProvenance(
            sourceBundleURL: bundleURL,
            inputFASTQURLs: fastqURLs,
            outputURL: outputURL,
            isDerived: false,
            startedAt: startedAt
        )
    }

    nonisolated private static func concatenateFASTQChunks(_ inputURLs: [URL], to outputURL: URL) async throws {
        let outputIsGzip = outputURL.isGzipCompressed
        let allInputsAreGzip = inputURLs.allSatisfy(\.isGzipCompressed)
        let noInputsAreGzip = inputURLs.allSatisfy { !$0.isGzipCompressed }

        if outputIsGzip && allInputsAreGzip || !outputIsGzip && noInputsAreGzip {
            try concatenateBytes(inputURLs, to: outputURL)
            return
        }

        if outputIsGzip {
            let tempDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("fastq-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDirectory) }
            let uncompressedURL = tempDirectory.appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent)
            try await writeUncompressedFASTQ(inputURLs, to: uncompressedURL)
            try gzipFile(uncompressedURL, to: outputURL)
            return
        }

        try await writeUncompressedFASTQ(inputURLs, to: outputURL)
    }

    nonisolated private static func concatenateBytes(_ inputURLs: [URL], to outputURL: URL) throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for inputURL in inputURLs {
            let inputHandle = try FileHandle(forReadingFrom: inputURL)
            do {
                defer { try? inputHandle.close() }
                while true {
                    let chunk = try inputHandle.read(upToCount: 1 << 20) ?? Data()
                    if chunk.isEmpty { break }
                    try outputHandle.write(contentsOf: chunk)
                }
            }
        }
    }

    nonisolated private static func writeUncompressedFASTQ(_ inputURLs: [URL], to outputURL: URL) async throws {
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        for try await line in URL.multiFileLinesAutoDecompressing(inputURLs) {
            try outputHandle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    nonisolated private static func gzipFile(_ inputURL: URL, to outputURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", inputURL.path]
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "com.lungfish.browser", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Compression failed for \(outputURL.lastPathComponent)."])
        }
    }

    nonisolated private static func removeExistingItemIfNeeded(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    nonisolated private static func writeFASTQExportProvenance(
        sourceBundleURL: URL,
        inputFASTQURLs: [URL],
        outputURL: URL,
        isDerived: Bool,
        startedAt: Date
    ) throws {
        let completedAt = Date()
        var inputRecords: [FileRecord]
        if inputFASTQURLs.isEmpty {
            inputRecords = [ProvenanceRecorder.fileRecord(url: sourceBundleURL, format: .unknown, role: .input)]
        } else {
            inputRecords = inputFASTQURLs.map {
                ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .input)
            }
        }

        let sourceManifestURL = sourceBundleURL.appendingPathComponent(FASTQSourceFileManifest.filename)
        if FileManager.default.fileExists(atPath: sourceManifestURL.path) {
            inputRecords.append(ProvenanceRecorder.fileRecord(url: sourceManifestURL, format: .json, role: .input))
        }
        let derivedManifestURL = FASTQBundle.derivedManifestURL(in: sourceBundleURL)
        if FileManager.default.fileExists(atPath: derivedManifestURL.path) {
            inputRecords.append(ProvenanceRecorder.fileRecord(url: derivedManifestURL, format: .json, role: .input))
        }

        let outputRecord = ProvenanceRecorder.fileRecord(url: outputURL, format: .fastq, role: .output)
        var argv = [
            "Lungfish Genome Explorer",
            "export-fastq",
            sourceBundleURL.path,
            "--output",
            outputURL.path,
        ]
        if isDerived {
            argv.append("--materialize-derived")
        }
        if inputFASTQURLs.count > 1 {
            argv.append(contentsOf: ["--source-chunks", "\(inputFASTQURLs.count)"])
        }

        let step = StepExecution(
            toolName: "Lungfish Genome Explorer FASTQ Export",
            toolVersion: WorkflowRun.currentAppVersion,
            command: argv,
            inputs: inputRecords,
            outputs: [outputRecord],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(startedAt),
            startTime: startedAt,
            endTime: completedAt
        )
        let run = WorkflowRun(
            name: "FASTQ Export",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            steps: [step],
            parameters: [
                "sourceBundle": .file(sourceBundleURL),
                "output": .file(outputURL),
                "isDerived": .boolean(isDerived),
                "inputChunkCount": .integer(inputFASTQURLs.count),
                "outputGzipCompressed": .boolean(outputURL.isGzipCompressed),
            ]
        )
        try ProvenanceWriter(signingProvider: nil).write(
            run.canonicalEnvelope(),
            toSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL)
        )
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
