// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishWorkflow
import LungfishKit
import os.log

extension InspectorViewController {
    // MARK: - Metadata Import

    private struct SampleMetadataImportContext {
        let knownSampleIds: Set<String>
        let bundleURL: URL?
        let applyStore: (SampleMetadataStore) -> Void
    }

    private enum InspectorSampleMetadataImportError: LocalizedError {
        case noImportContext
        case unreadableFile
        case noSampleColumn
        case writeDenied

        var errorDescription: String? {
            switch self {
            case .noImportContext:
                return "No sample list is available for the current result."
            case .unreadableFile:
                return "The selected metadata file could not be read."
            case .noSampleColumn:
                return "No column in this file contains values matching the known sample IDs."
            case .writeDenied:
                return "The current project cannot be modified right now."
            }
        }
    }

    @objc func handleMetadataImportRequested(_ notification: Notification) {
        _ = handleMetadataImportRequested(notification, shouldPresentPanel: true)
    }

    @discardableResult
    func handleMetadataImportRequested(
        _ notification: Notification,
        shouldPresentPanel: Bool
    ) -> Bool {
        guard shouldAcceptScopedNotification(notification) else { return false }
        guard shouldPresentPanel else { return true }

        presentMetadataImportPanel()
        return true
    }

    private func presentMetadataImportPanel() {
        let panel = FeatureFilePanelFactory.inspectorTextMetadataImportPanel()

        guard let window = self.view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.handleMetadataImport(from: url)
                }
            }
        }
    }

    private func handleMetadataImport(from url: URL) {
        guard let context = currentSampleMetadataImportContext() else {
            showMetadataImportAlert(
                title: "No Samples Available",
                message: InspectorSampleMetadataImportError.noImportContext.localizedDescription
            )
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            showMetadataImportAlert(
                title: "Metadata Import Failed",
                message: InspectorSampleMetadataImportError.unreadableFile.localizedDescription
            )
            return
        }

        guard let scanResult = try? SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: context.knownSampleIds
        ) else {
            showMetadataImportAlert(
                title: "Metadata Import Failed",
                message: InspectorSampleMetadataImportError.unreadableFile.localizedDescription
            )
            return
        }

        guard let best = scanResult.bestColumn else {
            showMetadataImportAlert(
                title: "No Sample Column Found",
                message: "No column in this file contains values matching the known sample IDs. Check that your metadata file includes a column with sample names."
            )
            return
        }

        if best.matchCount == scanResult.totalRows {
            finishMetadataImportAndReportErrors(
                data: data,
                sourceURL: url,
                scanResult: scanResult,
                sampleColumnIndex: best.index,
                context: context
            )
        } else {
            let alert = NSAlert()
            alert.messageText = "Confirm Sample Column"
            alert.informativeText = "Column \"\(best.name)\" matched \(best.matchCount) of \(scanResult.totalRows) rows to sample IDs. Use this column?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Use \"\(best.name)\"")
            if scanResult.candidates.count > 1 {
                alert.addButton(withTitle: "Choose Another\u{2026}")
            }
            alert.addButton(withTitle: "Cancel")

            guard let window = self.view.window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch response {
                        case .alertFirstButtonReturn:
                            self.finishMetadataImportAndReportErrors(
                                data: data,
                                sourceURL: url,
                                scanResult: scanResult,
                                sampleColumnIndex: best.index,
                                context: context
                            )
                        case .alertSecondButtonReturn where scanResult.candidates.count > 1:
                            self.showSampleColumnPicker(
                                data: data,
                                sourceURL: url,
                                scanResult: scanResult,
                                context: context
                            )
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    private func showSampleColumnPicker(
        data: Data,
        sourceURL: URL,
        scanResult: MetadataColumnScanResult,
        context: SampleMetadataImportContext
    ) {
        let alert = NSAlert()
        alert.messageText = "Select Sample Column"
        alert.informativeText = "Choose which column contains sample IDs:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 25), pullsDown: false)
        for candidate in scanResult.candidates {
            popup.addItem(withTitle: "\(candidate.name) (\(candidate.matchCount) of \(scanResult.totalRows) matched)")
            popup.lastItem?.tag = candidate.index
        }
        alert.accessoryView = popup

        guard let window = self.view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, response == .alertFirstButtonReturn else { return }
                    let selectedIndex = popup.selectedItem?.tag ?? scanResult.candidates[0].index
                    self.finishMetadataImportAndReportErrors(
                        data: data,
                        sourceURL: sourceURL,
                        scanResult: scanResult,
                        sampleColumnIndex: selectedIndex,
                        context: context
                    )
                }
            }
        }
    }

    private func currentSampleMetadataImportContext() -> SampleMetadataImportContext? {
        if let genotypeDocument = viewModel.documentSectionViewModel.genotypeResultDocument {
            guard !genotypeDocument.sampleIds.isEmpty else { return nil }
            return SampleMetadataImportContext(
                knownSampleIds: Set(genotypeDocument.sampleIds),
                bundleURL: genotypeDocument.bundleURL,
                applyStore: { [weak self] store in
                    guard let self,
                          let state = self.viewModel.documentSectionViewModel.genotypeResultDocument else { return }
                    self.viewModel.documentSectionViewModel.updateGenotypeResultDocument(
                        state.replacing(sampleMetadataStore: store)
                    )
                    self.onGenotypeSampleMetadataImported?(store)
                }
            )
        }

        let classifierSampleIds = Set(viewModel.documentSectionViewModel.classifierSampleEntries.map(\.id))
        guard !classifierSampleIds.isEmpty else { return nil }
        return SampleMetadataImportContext(
            knownSampleIds: classifierSampleIds,
            bundleURL: viewModel.documentSectionViewModel.bundleAttachmentStore?.bundleURL,
            applyStore: { [weak self] store in
                self?.viewModel.documentSectionViewModel.sampleMetadataStore = store
            }
        )
    }

    private func finishMetadataImportAndReportErrors(
        data: Data,
        sourceURL: URL,
        scanResult: MetadataColumnScanResult,
        sampleColumnIndex: Int,
        context: SampleMetadataImportContext
    ) {
        do {
            _ = try finishMetadataImport(
                data: data,
                sourceURL: sourceURL,
                scanResult: scanResult,
                sampleColumnIndex: sampleColumnIndex,
                context: context
            )
        } catch {
            showMetadataImportAlert(
                title: "Metadata Import Failed",
                message: error.localizedDescription
            )
        }
    }

    @discardableResult
    private func finishMetadataImport(
        data: Data,
        sourceURL: URL,
        scanResult: MetadataColumnScanResult,
        sampleColumnIndex: Int,
        context: SampleMetadataImportContext
    ) throws -> SampleMetadataStore {
        if let bundleURL = context.bundleURL,
           !canWriteProjectOutputs(bundleURL: bundleURL, workflowName: "Sample metadata import") {
            throw InspectorSampleMetadataImportError.writeDenied
        }

        let result = try SampleMetadataBundleImportService().importMetadata(
            data: data,
            sourceURL: sourceURL,
            scanResult: scanResult,
            sampleColumnIndex: sampleColumnIndex,
            knownSampleIds: context.knownSampleIds,
            bundleURL: context.bundleURL
        )
        context.applyStore(result.store)
        return result.store
    }

    private func showMetadataImportAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = self.view.window {
            alert.beginSheetModal(for: window)
        }
    }

    func testingImportMetadata(from url: URL) throws {
        guard let context = currentSampleMetadataImportContext() else {
            throw InspectorSampleMetadataImportError.noImportContext
        }
        guard let data = try? Data(contentsOf: url) else {
            throw InspectorSampleMetadataImportError.unreadableFile
        }
        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: context.knownSampleIds
        )
        guard let best = scanResult.bestColumn else {
            throw InspectorSampleMetadataImportError.noSampleColumn
        }
        try finishMetadataImport(
            data: data,
            sourceURL: url,
            scanResult: scanResult,
            sampleColumnIndex: best.index,
            context: context
        )
    }

    /// Updates the NVD manifest in the Document section.
    ///
    /// - Parameter manifest: The NVD manifest, or nil to clear
    public func updateNvdManifest(_ manifest: NvdManifest?) {
        viewModel.documentSectionViewModel.updateNvdManifest(manifest)
    }

    func assemblyContextRows(
        result: AssemblyResult,
        provenance: AssemblyProvenance?
    ) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Assembler", provenance?.assembler ?? result.tool.displayName),
            ("Read Type", result.readType.displayName),
        ]

        if let version = provenance?.assemblerVersion ?? result.assemblerVersion, !version.isEmpty {
            rows.append(("Version", version))
        }
        if let provenance {
            rows.append(("Execution Backend", provenance.executionBackend.rawValue))
            if let managedEnvironment = provenance.managedEnvironment, !managedEnvironment.isEmpty {
                rows.append(("Environment", managedEnvironment))
            }
            if let launcherCommand = provenance.launcherCommand, !launcherCommand.isEmpty {
                rows.append(("Launcher", launcherCommand))
            }
            rows.append(("Run Date", Self.assemblyDateFormatter.string(from: provenance.assemblyDate)))
            rows.append(("Host", "\(provenance.hostOS) • \(provenance.hostArchitecture)"))
            rows.append(("Lungfish", provenance.lungfishVersion))
            rows.append(("Mode", provenance.parameters.mode))
            rows.append(("K-mer Sizes", provenance.parameters.kmerSizes))
            rows.append(("Threads", String(provenance.parameters.threads)))
            rows.append(("Memory", "\(provenance.parameters.memoryGB) GB"))
            rows.append(("Minimum Contig Length", "\(provenance.parameters.minContigLength) bp"))
        }

        rows.append(("Wall Time", String(format: "%.1fs", result.wallTimeSeconds)))
        rows.append(("Contigs", "\(result.statistics.contigCount)"))
        rows.append(("Total Assembled bp", "\(result.statistics.totalLengthBP)"))
        rows.append(("N50", "\(result.statistics.n50) bp"))
        rows.append(("L50", "\(result.statistics.l50)"))
        rows.append(("Longest Contig", "\(result.statistics.largestContigBP) bp"))
        rows.append(("Global GC", String(format: "%.1f%%", result.statistics.gcPercent)))
        rows.append(("Command", provenance?.commandLine ?? result.commandLine))
        rows.append(("Output Directory", result.outputDirectory.path))

        return rows
    }

    func assemblyArtifactRows(result: AssemblyResult) -> [AssemblyDocumentArtifactRow] {
        [
            .init(label: "Contigs FASTA", fileURL: result.contigsPath),
            .init(label: "Scaffolds FASTA", fileURL: result.scaffoldsPath),
            .init(label: "Graph", fileURL: result.graphPath),
            .init(label: "Log", fileURL: result.logPath),
            .init(label: "Parameters", fileURL: result.paramsPath),
            .init(
                label: "Provenance",
                fileURL: result.outputDirectory.appendingPathComponent(AssemblyProvenance.filename)
            ),
        ]
    }

    private static let assemblyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Injects the shared AI assistant service used by the embedded inspector tab.
    public func setAIAssistantService(_ service: AIAssistantService) {
        viewModel.aiAssistantService = service
    }

    /// Populates the sample section view model from the bundle's variant databases.
    ///
    /// Opens each variant database and aggregates sample names and metadata field names.
    func updateSampleSection(from bundle: ReferenceBundle) {
        var allSampleNames: [String] = []
        var sampleNameSet = Set<String>()
        var allMetadataFields: Set<String> = []
        var allSampleMetadata: [String: [String: String]] = [:]
        var allSourceFiles: [String: String] = [:]
        var dbByTrackId: [String: VariantDatabase] = [:]
        var variantDBURLs: [URL] = []

        for vTrackId in bundle.variantTrackIds {
            guard let trackInfo = bundle.variantTrack(id: vTrackId),
                  let dbPath = trackInfo.databasePath else { continue }
            guard let dbURL = try? BundleManifest.validatedBundleMemberURL(
                for: dbPath,
                in: bundle.url,
                field: "variants[\(vTrackId)].databasePath"
            ) else { continue }
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            do {
                let db = try VariantDatabase(url: dbURL)
                dbByTrackId[vTrackId] = db
                variantDBURLs.append(dbURL)
                for name in db.sampleNames() where sampleNameSet.insert(name).inserted {
                    allSampleNames.append(name)
                }
                let fields = db.metadataFieldNames()
                allMetadataFields.formUnion(fields)

                // Load per-sample metadata and source files
                for (name, metadata) in db.allSampleMetadata() {
                    allSampleMetadata[name] = metadata
                }
                let sources = db.allSourceFiles()
                for (name, file) in sources {
                    allSourceFiles[name] = file
                }
            } catch {
                inspectorLogger.warning("updateSampleSection: Failed to open variant database '\(vTrackId, privacy: .public)': \(error.localizedDescription)")
            }
        }

        let sampleCount = allSampleNames.count
        viewModel.sampleSectionViewModel.update(
            sampleCount: sampleCount,
            sampleNames: allSampleNames,
            metadataFields: allMetadataFields.sorted(),
            sampleMetadata: allSampleMetadata,
            sourceFiles: allSourceFiles
        )

        // Wire save callback for metadata editing
        let capturedURLs = variantDBURLs
        let capturedBundleURL = bundle.url
        viewModel.sampleSectionViewModel.onSaveMetadata = { [weak self] sampleName, metadata in
            guard self?.canWriteProjectOutputs(
                bundleURL: capturedBundleURL,
                workflowName: "Sample metadata edit"
            ) == true else { return }
            do {
                let targets = capturedURLs.map {
                    VariantSampleMetadataImportTarget(databaseURL: $0)
                }
                let result = try VariantSampleMetadataMutationService().updateSampleMetadata(
                    sampleName: sampleName,
                    metadata: metadata,
                    bundleURL: capturedBundleURL,
                    targets: targets
                )
                inspectorLogger.info("updateSampleSection: Saved metadata for '\(sampleName)' to \(result.totalUpdated) variant database(s)")
            } catch {
                inspectorLogger.warning("updateSampleSection: Failed to save metadata: \(error.localizedDescription)")
            }
        }

        // Wire import callback
        viewModel.sampleSectionViewModel.onImportMetadata = { [weak self] in
            self?.presentMetadataImportPanel(variantDBURLs: capturedURLs, bundle: bundle)
        }

        // Wire variant databases for track-aware genotype lookups.
        viewModel.variantSectionViewModel.variantDatabasesByTrackId = dbByTrackId

        inspectorLogger.info("updateSampleSection: \(sampleCount) samples, \(allMetadataFields.count) metadata fields, \(allSourceFiles.count) source files")
    }

    /// Presents an open panel for importing sample metadata from TSV/CSV.
    private func presentMetadataImportPanel(variantDBURLs: [URL], bundle: ReferenceBundle) {
        guard canWriteProjectOutputs(bundleURL: bundle.url, workflowName: "Sample metadata import") else {
            return
        }
        let panel = FeatureFilePanelFactory.variantSampleMetadataImportPanel()

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let fileURL = panel.url else { return }
            guard self?.canWriteProjectOutputs(
                bundleURL: bundle.url,
                workflowName: "Sample metadata import"
            ) == true else { return }
            let ext = fileURL.pathExtension.lowercased()
            let format: MetadataFormat = ext == "csv" ? .csv : .tsv

            do {
                let targets = variantDBURLs.map {
                    VariantSampleMetadataImportTarget(databaseURL: $0)
                }
                let result = try VariantSampleMetadataImportService().importMetadata(
                    from: fileURL,
                    format: format,
                    bundleURL: bundle.url,
                    targets: targets
                )
                inspectorLogger.info("importSampleMetadata: Updated \(result.totalUpdated) samples from \(fileURL.lastPathComponent)")
                // Refresh the sample section
                self?.updateSampleSection(from: bundle)
            } catch {
                inspectorLogger.warning("importSampleMetadata: \(error.localizedDescription)")
            }
        }
    }

    func makeReadDisplaySettingsPayload(from vm: ReadStyleSectionViewModel) -> [AnyHashable: Any] {
        [
            NotificationUserInfoKey.showReads: vm.showReads,
            NotificationUserInfoKey.maxReadRows: Int(vm.maxReadRows),
            NotificationUserInfoKey.limitReadRows: vm.limitReadRows,
            NotificationUserInfoKey.verticalCompressContig: vm.verticallyCompressContig,
            NotificationUserInfoKey.minMapQ: Int(vm.minMapQ),
            NotificationUserInfoKey.showMismatches: vm.showMismatches,
            NotificationUserInfoKey.showSoftClips: vm.showSoftClips,
            NotificationUserInfoKey.showIndels: vm.showIndels,
            NotificationUserInfoKey.showStrandColors: vm.showStrandColors,
            NotificationUserInfoKey.consensusMaskingEnabled: vm.consensusMaskingEnabled,
            NotificationUserInfoKey.consensusGapThresholdPercent: Int(vm.consensusGapThresholdPercent),
            NotificationUserInfoKey.consensusMinDepth: Int(vm.consensusMinDepth),
            NotificationUserInfoKey.consensusMaskingMinDepth: Int(vm.consensusMaskingMinDepth),
            NotificationUserInfoKey.consensusMinMapQ: Int(vm.consensusMinMapQ),
            NotificationUserInfoKey.consensusMinBaseQ: Int(vm.consensusMinBaseQ),
            NotificationUserInfoKey.showConsensusTrack: vm.showConsensusTrack,
            NotificationUserInfoKey.consensusMode: vm.consensusMode.rawValue,
            NotificationUserInfoKey.consensusUseAmbiguity: vm.consensusUseAmbiguity,
            NotificationUserInfoKey.excludeFlags: vm.computedExcludeFlags,
            NotificationUserInfoKey.selectedReadGroups: vm.selectedReadGroups,
            NotificationUserInfoKey.visibleAlignmentTrackID: vm.selectedVisibleAlignmentTrackID ?? "",
            NotificationUserInfoKey.msaNumberingMode: vm.msaNumberingMode.rawValue,
            NotificationUserInfoKey.msaConsensusLowSupportThresholdPercent: Int(vm.msaConsensusLowSupportThresholdPercent),
            NotificationUserInfoKey.msaConsensusHighGapThresholdPercent: Int(vm.msaConsensusHighGapThresholdPercent),
            NotificationUserInfoKey.msaConsensusMaskSymbolMode: vm.msaConsensusMaskSymbolMode.rawValue,
            NotificationUserInfoKey.msaReferenceRowID: vm.selectedMSAReferenceRowID ?? "",
            NotificationUserInfoKey.msaResidueIdentityDisplayMode: vm.msaResidueIdentityDisplayMode.rawValue,
        ]
    }

    private func syncAlignmentTrackInventory(from bundle: ReferenceBundle) {
        viewModel.documentSectionViewModel.updateAlignmentTrackInventory(
            from: bundle,
            visibleTrackID: viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
        )
        viewModel.documentSectionViewModel.selectVisibleAlignmentTrack = { [weak self] trackID in
            self?.setVisibleAlignmentTrackSelection(trackID)
        }
        viewModel.documentSectionViewModel.removeDerivedAlignmentTrack = { [weak self] trackID in
            self?.removeDerivedAlignmentTrack(trackID)
        }
    }

    private func setVisibleAlignmentTrackSelection(_ trackID: String?) {
        viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID = trackID
        viewModel.documentSectionViewModel.visibleAlignmentTrackID = trackID
        viewModel.readStyleSectionViewModel.onSettingsChanged?()
    }

    private func removeDerivedAlignmentTrack(_ trackID: String) {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before removing a derived alignment.")
            return
        }
        guard let row = viewModel.documentSectionViewModel.alignmentTrackRows.first(where: { $0.id == trackID }),
              row.isDerived else {
            presentSimpleAlert(title: "Source Alignment", message: "Only derived filtered alignments can be removed from this control.")
            return
        }
        guard let split = parent as? MainSplitViewController else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        confirmRemoveDerivedAlignment(rowName: row.name) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.runRemoveDerivedAlignmentWorkflow(
                trackID: trackID,
                trackName: row.name,
                bundleURL: bundleURL,
                shouldReloadMappingViewer: split.viewerController.activeMappingViewportController != nil
            )
        }
    }

    private func confirmRemoveDerivedAlignment(
        rowName: String,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Remove Derived Alignment?"
        alert.informativeText = "This removes \"\(rowName)\" and its BAM, index, and metadata files from this bundle. The source alignment is not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.applyLungfishDestructiveStyle()

        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            NSSound.beep()
            completion(false)
        }
    }

    private func runRemoveDerivedAlignmentWorkflow(
        trackID: String,
        trackName: String,
        bundleURL: URL,
        shouldReloadMappingViewer: Bool
    ) {
        guard canWriteProjectOutputs(bundleURL: bundleURL, workflowName: "Derived alignment removal") else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        let operationID = OperationCenter.shared.start(
            title: "Remove Derived Alignment",
            detail: "Removing \(trackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL,
            routeContext: operationRouteContext(for: bundleURL)
        )

        Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await BundleAlignmentTrackRemovalService()
                    .removeDerivedAlignmentTrack(bundleURL: bundleURL, trackID: trackID)

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              let split = self.parent as? MainSplitViewController else { return }

                        split.sidebarController.requestReloadFromFilesystem()
                        do {
                            if self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID == result.removedTrack.id {
                                self.setVisibleAlignmentTrackSelection(nil)
                            }
                            if shouldReloadMappingViewer {
                                try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                            } else {
                                try split.viewerController.displayBundle(at: bundleURL)
                            }
                            _ = OperationCenter.shared.complete(
                                id: operationID,
                                detail: "Removed derived alignment track \"\(result.removedTrack.name)\"."
                            )
                        } catch {
                            _ = OperationCenter.shared.fail(id: operationID, detail: error.localizedDescription)
                            self.presentSimpleAlert(
                                title: shouldReloadMappingViewer ? "Mapping Viewer Reload Failed" : "Reload Failed",
                                message: "The derived alignment was removed, but the updated bundle could not be reloaded: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(
                            id: operationID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                        self?.presentSimpleAlert(
                            title: "Remove Derived Alignment Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    /// Populates the read style section with alignment statistics from the bundle's metadata DBs.
    func updateAlignmentSection(from bundle: ReferenceBundle) {
        viewModel.documentSectionViewModel.referenceTrackCapabilities =
            ReferenceBundleTrackCapabilities(bundle: bundle)
        viewModel.readStyleSectionViewModel.loadStatistics(from: bundle)
        syncAlignmentTrackInventory(from: bundle)
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = false
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = nil

        // Wire the settings-changed callback to post notification
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.viewModel.documentSectionViewModel.visibleAlignmentTrackID =
                self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
            NotificationCenter.default.post(
                name: .readDisplaySettingsChanged,
                object: self,
                userInfo: self.windowScopedUserInfo(
                    self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel)
                )
            )
        }

        viewModel.readStyleSectionViewModel.onMarkDuplicatesRequested = { [weak self] in
            self?.runMarkDuplicatesWorkflow()
        }

        viewModel.readStyleSectionViewModel.onCreateDeduplicatedBundleRequested = { [weak self] in
            self?.runCreateDeduplicatedBundleWorkflow()
        }

        viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = { [weak self] request in
            self?.runCreateFilteredAlignmentWorkflow(request)
        }

        viewModel.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested = { [weak self] request in
            self?.runConvertMappedReadsToAnnotationsWorkflow(request)
        }

        viewModel.readStyleSectionViewModel.onCallVariantsRequested = { [weak self] in
            self?.runCallVariantsWorkflow()
        }

        viewModel.readStyleSectionViewModel.onPrimerTrimRequested = { [weak self] in
            self?.runPrimerTrimWorkflow()
        }

        inspectorLogger.info("updateAlignmentSection: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

    func updateMappingAlignmentSection(
        from bundle: ReferenceBundle,
        applySettings: @escaping ([AnyHashable: Any]) -> Void
    ) {
        viewModel.selectionSectionViewModel.referenceBundle = bundle
        viewModel.documentSectionViewModel.bundleURL = bundle.url
        viewModel.documentSectionViewModel.referenceTrackCapabilities =
            ReferenceBundleTrackCapabilities(bundle: bundle)
        viewModel.readStyleSectionViewModel.loadStatistics(from: bundle)
        syncAlignmentTrackInventory(from: bundle)
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = true
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.viewModel.documentSectionViewModel.visibleAlignmentTrackID =
                self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
            applySettings(self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel))
        }
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = { [weak self] in
            guard let self,
                  let split = self.parent as? MainSplitViewController else { return }
            split.viewerController.presentMappingConsensusExtraction()
        }
        viewModel.readStyleSectionViewModel.onMarkDuplicatesRequested = { [weak self] in
            self?.runMarkDuplicatesWorkflow()
        }
        viewModel.readStyleSectionViewModel.onCreateDeduplicatedBundleRequested = { [weak self] in
            self?.runCreateDeduplicatedBundleWorkflow()
        }
        viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = { [weak self] request in
            self?.runCreateFilteredAlignmentWorkflow(request)
        }
        viewModel.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested = { [weak self] request in
            self?.runConvertMappedReadsToAnnotationsWorkflow(request)
        }
        viewModel.readStyleSectionViewModel.onCallVariantsRequested = { [weak self] in
            self?.runCallVariantsWorkflow()
        }
        viewModel.readStyleSectionViewModel.onPrimerTrimRequested = { [weak self] in
            self?.runPrimerTrimWorkflow()
        }
        applySettings(makeReadDisplaySettingsPayload(from: viewModel.readStyleSectionViewModel))
        inspectorLogger.info("updateMappingAlignmentSection: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

    func updateReferenceBundleTrackSections(
        from bundle: ReferenceBundle,
        applySettings: @escaping ([AnyHashable: Any]) -> Void
    ) {
        updateReferenceBundleDocumentState(
            manifest: bundle.manifest,
            bundleURL: bundle.url,
            bundle: bundle
        )
        updateAlignmentSection(from: bundle)
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = false
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = nil
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.viewModel.documentSectionViewModel.visibleAlignmentTrackID =
                self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
            applySettings(self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel))
        }
        applySettings(makeReadDisplaySettingsPayload(from: viewModel.readStyleSectionViewModel))
        inspectorLogger.info("updateReferenceBundleTrackSections: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

}
