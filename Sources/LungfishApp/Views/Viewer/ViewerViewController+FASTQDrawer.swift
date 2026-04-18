// ViewerViewController+FASTQDrawer.swift - FASTQ metadata drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import os.log

private let fastqDrawerLogger = Logger(subsystem: LogSubsystem.app, category: "ViewerFASTQDrawer")
private let fastqDrawerHeight: CGFloat = 360

/// Minimum visible content left above the FASTQ drawer during resize.
private let fastqDrawerVisibleHostStrip: CGFloat = 80

extension ViewerViewController: FASTQMetadataDrawerViewDelegate {

    public func toggleFASTQMetadataDrawer() {
        guard isDisplayingFASTQDataset else { return }

        if fastqMetadataDrawerView == nil {
            configureFASTQMetadataDrawer()
        }

        guard let bottomConstraint = fastqMetadataDrawerBottomConstraint else { return }
        let isOpen = isFASTQMetadataDrawerOpen
        let currentHeight = fastqMetadataDrawerHeightConstraint?.constant ?? fastqDrawerHeight
        let target: CGFloat = isOpen ? currentHeight : 0

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            bottomConstraint.animator().constant = target
            view.layoutSubtreeIfNeeded()
        }

        isFASTQMetadataDrawerOpen = !isOpen
        if isFASTQMetadataDrawerOpen {
            refreshFASTQMetadataDrawerContent()
        }
        fastqDrawerLogger.info("toggleFASTQMetadataDrawer: open=\(self.isFASTQMetadataDrawerOpen)")
    }

    func configureFASTQMetadataDrawer() {
        guard fastqMetadataDrawerView == nil else { return }

        let drawer = FASTQMetadataDrawerView(delegate: self)
        drawer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawer)

        let persistedHeight = UserDefaults.standard.double(forKey: "fastqMetadataDrawerHeight")
        let drawerHeight = persistedHeight > 0 ? CGFloat(persistedHeight) : fastqDrawerHeight
        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: drawerHeight)
        let heightConstraint = drawer.heightAnchor.constraint(equalToConstant: drawerHeight)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,
            bottomConstraint,
        ])

        fastqMetadataDrawerView = drawer
        fastqMetadataDrawerBottomConstraint = bottomConstraint
        fastqMetadataDrawerHeightConstraint = heightConstraint
        isFASTQMetadataDrawerOpen = false

        drawer.onDedupConfigChanged = { [weak self] preset, subs, optical, dist in
            self?.fastqDatasetController?.updateDedupConfig(
                preset: preset, substitutions: subs, optical: optical, opticalDistance: dist
            )
        }

        if let dashboardView = fastqDashboardView {
            fastqDashboardBottomConstraint?.isActive = false
            let replacement = dashboardView.bottomAnchor.constraint(equalTo: drawer.topAnchor)
            replacement.isActive = true
            fastqDashboardBottomConstraint = replacement
        }

        refreshFASTQMetadataDrawerContent()
    }

    func teardownFASTQMetadataDrawer() {
        fastqMetadataDrawerView?.removeFromSuperview()
        fastqMetadataDrawerView = nil
        fastqMetadataDrawerBottomConstraint = nil
        fastqMetadataDrawerHeightConstraint = nil
        isFASTQMetadataDrawerOpen = false
    }

    func refreshFASTQMetadataDrawerContent() {
        guard let drawer = fastqMetadataDrawerView else { return }
        let metadata = currentFASTQDatasetURL.flatMap { FASTQMetadataStore.load(for: $0)?.demultiplexMetadata }
        drawer.configure(fastqURL: currentFASTQDatasetURL, metadata: metadata)
        syncDemuxConfigToController()
    }

    public func fastqMetadataDrawerViewDidSave(
        _ drawer: FASTQMetadataDrawerView,
        fastqURL: URL?,
        metadata: FASTQDemultiplexMetadata
    ) {
        guard let targetURL = fastqURL ?? currentFASTQDatasetURL else { return }

        var persisted = FASTQMetadataStore.load(for: targetURL) ?? PersistedFASTQMetadata()
        persisted.demultiplexMetadata = metadata
        FASTQMetadataStore.save(persisted, for: targetURL)
        syncDemuxConfigToController()
        fastqDrawerLogger.info("Saved FASTQ demultiplex metadata for \(targetURL.lastPathComponent, privacy: .public)")
    }

    public func fastqMetadataDrawerViewDidRequestScout(
        _ drawer: FASTQMetadataDrawerView,
        step: DemultiplexStep
    ) {
        guard let fastqURL = currentFASTQDatasetURL else {
            fastqDrawerLogger.warning("Scout requested but no FASTQ URL is set")
            return
        }
        guard let kit = BarcodeKitRegistry.kit(byID: step.barcodeKitID) else {
            fastqDrawerLogger.warning("Scout requested but barcode kit '\(step.barcodeKitID)' not found")
            return
        }

        let pipeline = DemultiplexingPipeline()
        let detectedPlatform = LungfishIO.SequencingPlatform.detect(fromFASTQ: FASTQBundle.resolvePrimaryFASTQURL(for: fastqURL) ?? fastqURL)
        fastqDrawerLogger.info("Starting barcode scout for \(fastqURL.lastPathComponent, privacy: .public) with kit \(step.barcodeKitID, privacy: .public), detected platform: \(detectedPlatform?.displayName ?? "unknown", privacy: .public)")

        drawer.updateScoutStatus("Scouting barcodes...")

        Task.detached { [weak self] in
            do {
                let result = try await pipeline.scout(
                    inputURL: fastqURL,
                    kit: kit,
                    sourcePlatform: step.sourcePlatform ?? detectedPlatform,
                    errorRate: step.errorRate,
                    minimumOverlap: step.minimumOverlap,
                    searchReverseComplement: step.searchReverseComplement,
                    useNoIndels: !step.allowIndels,
                    readLimit: 10_000,
                    progress: { _, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                self?.fastqMetadataDrawerView?.updateScoutStatus(message)
                            }
                        }
                    }
                )
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.view.window else { return }
                        BarcodeScoutSheet.present(
                            on: window,
                            scoutResult: result,
                            kitDisplayName: kit.displayName,
                            onProceed: { [weak self] acceptedDetections, scoutResult in
                                self?.handleScoutProceed(
                                    acceptedDetections: acceptedDetections,
                                    scoutResult: scoutResult,
                                    kit: kit
                                )
                            }
                        )
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard self != nil else { return }
                        fastqDrawerLogger.error("Barcode scout failed: \(error)")
                        let alert = NSAlert()
                        alert.messageText = "Barcode Detection Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        if let window = self?.view.window {
                            alert.beginSheetModal(for: window, completionHandler: nil)
                        }
                    }
                }
            }
        }
    }

    public func fastqMetadataDrawerViewDidChangeDemuxPlan(
        _ drawer: FASTQMetadataDrawerView,
        plan: DemultiplexPlan
    ) {
        syncDemuxConfigToController()
    }

    /// Handles the user clicking "Proceed" in the BarcodeScoutSheet after reviewing scout results.
    /// Converts accepted detections into sample assignments, updates the demux config, and
    /// triggers the full demultiplexing run via the operations panel.
    private func handleScoutProceed(
        acceptedDetections: [BarcodeDetection],
        scoutResult: BarcodeScoutResult,
        kit: BarcodeKitDefinition
    ) {
        // Convert accepted detections to sample assignments.
        // For combinatorial kits, scout detection IDs are in pair format "bc1001--bc1096".
        // For fixedDual kits, scout detection IDs are single barcode IDs (no "--").
        let assignments: [FASTQSampleBarcodeAssignment] = acceptedDetections.map { detection in
            if kit.pairingMode == .combinatorialDual {
                let parts = detection.barcodeID.components(separatedBy: "--")
                if parts.count == 2 {
                    let fwdID = parts[0]
                    let revID = parts[1]
                    let fwdBarcode = kit.barcodes.first { $0.id == fwdID }
                    let revBarcode = kit.barcodes.first { $0.id == revID }
                    return FASTQSampleBarcodeAssignment(
                        sampleID: detection.barcodeID,
                        sampleName: detection.sampleName,
                        forwardBarcodeID: fwdID,
                        forwardSequence: fwdBarcode?.i7Sequence,
                        reverseBarcodeID: revID,
                        reverseSequence: revBarcode?.i7Sequence
                    )
                }
            }
            // Symmetric/single-end fallback
            let barcode = kit.barcodes.first { $0.id == detection.barcodeID }
            return FASTQSampleBarcodeAssignment(
                sampleID: detection.barcodeID,
                sampleName: detection.sampleName,
                forwardBarcodeID: detection.barcodeID,
                forwardSequence: barcode?.i7Sequence,
                reverseBarcodeID: detection.barcodeID,
                reverseSequence: barcode?.i5Sequence ?? barcode?.i7Sequence
            )
        }

        // Update the drawer's demux step with sample assignments
        if let drawer = fastqMetadataDrawerView {
            drawer.updateSampleAssignments(assignments)
            drawer.applySampleAssignmentsToCurrentStep(assignments)
            drawer.updateScoutStatus("\(acceptedDetections.count) barcode\(acceptedDetections.count == 1 ? "" : "s") configured. Click Run to start demultiplexing.")
        }

        // Sync to the operations panel but do NOT auto-trigger the run.
        // The user should review the generated pattern before committing.
        syncDemuxConfigToController()

        fastqDrawerLogger.info("Scout proceed: \(acceptedDetections.count) barcodes accepted, ready for manual run")
    }

    /// Syncs the drawer's first demux step to the operations panel as the current config.
    func syncDemuxConfigToController() {
        guard let drawer = fastqMetadataDrawerView else { return }
        let firstStep = drawer.currentDemuxPlan().steps.sorted(by: { $0.ordinal < $1.ordinal }).first
        fastqDatasetController?.currentDemuxConfig = firstStep
        fastqDatasetController?.currentPrimerTrimConfiguration = drawer.currentPrimerTrimConfiguration()
    }

    /// Opens the metadata drawer and selects the Demux tab.
    func openDemuxSetupDrawer() {
        if fastqMetadataDrawerView == nil {
            configureFASTQMetadataDrawer()
        }
        if !isFASTQMetadataDrawerOpen {
            toggleFASTQMetadataDrawer()
        }
        fastqMetadataDrawerView?.selectDemuxTab()
    }

    func openPrimerTrimDrawer() {
        if fastqMetadataDrawerView == nil {
            configureFASTQMetadataDrawer()
        }
        if !isFASTQMetadataDrawerOpen {
            toggleFASTQMetadataDrawer()
        }
        fastqMetadataDrawerView?.selectPrimerTrimTab()
    }

    func openDedupDrawer() {
        if fastqMetadataDrawerView == nil {
            configureFASTQMetadataDrawer()
        }
        if !isFASTQMetadataDrawerOpen {
            toggleFASTQMetadataDrawer()
        }
        fastqMetadataDrawerView?.selectDedupTab()
    }

    // MARK: - Drag-to-Resize

    public func fastqMetadataDrawerDidDragDivider(_ drawer: FASTQMetadataDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = fastqMetadataDrawerHeightConstraint else { return }
        let newHeight = MetagenomicsPaneSizing.clampedDrawerExtent(
            proposed: heightConstraint.constant + deltaY,
            containerExtent: view.bounds.height,
            minimumDrawerExtent: 150,
            minimumSiblingExtent: fastqDrawerVisibleHostStrip
        )
        heightConstraint.constant = newHeight
        fastqMetadataDrawerBottomConstraint?.constant = 0  // Keep visible while dragging
        view.layoutSubtreeIfNeeded()
        // Defer UserDefaults write -- mouseDragged fires at 60+ Hz
        _fastqDrawerHeightSaveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let height = self.fastqMetadataDrawerHeightConstraint?.constant ?? fastqDrawerHeight
                UserDefaults.standard.set(Double(height), forKey: "fastqMetadataDrawerHeight")
            }
        }
        _fastqDrawerHeightSaveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    public func fastqMetadataDrawerDidFinishDraggingDivider(_ drawer: FASTQMetadataDrawerView) {
        // Flush the debounced save immediately on drag end
        _fastqDrawerHeightSaveWorkItem?.cancel()
        _fastqDrawerHeightSaveWorkItem = nil
        if let height = fastqMetadataDrawerHeightConstraint?.constant {
            UserDefaults.standard.set(Double(height), forKey: "fastqMetadataDrawerHeight")
        }
    }
}
