// ViewerViewController+FASTQDrawer.swift - FASTQ metadata drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
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

        drawer.onDemultiplex = { [weak self] plan, kits in self?.openDemultiplexDialog(for: plan, kits: kits) }
        fastqDatasetContainer?.endDashboard(at: drawer.topAnchor)

        refreshFASTQMetadataDrawerContent()
    }

    func teardownFASTQMetadataDrawer() {
        keepWaitingFASTQDrawerEdit()
        // The drawer the close sheet spoke of goes now, and an edit made in the next one is the person's to hear of.
        fastqDrawerEditReportedByCloseSheet = false
        fastqMetadataDrawerView?.removeFromSuperview()
        fastqMetadataDrawerView = nil
        fastqMetadataDrawerBottomConstraint = nil
        fastqMetadataDrawerHeightConstraint = nil
        isFASTQMetadataDrawerOpen = false
    }

    func refreshFASTQMetadataDrawerContent() {
        guard let drawer = fastqMetadataDrawerView else { return }
        keepWaitingFASTQDrawerEdit()
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
        do {
            try writeFASTQDrawerMetadata(metadata, to: targetURL)
            drawer.markSettingsKept()
            fastqDrawerLogger.info("Saved FASTQ demultiplex metadata for \(targetURL.lastPathComponent, privacy: .public)")
        } catch {
            fastqDrawerLogger.warning("Failed to save FASTQ demultiplex metadata for \(targetURL.lastPathComponent, privacy: .public): \(error)")
        }
    }

    /// Save's one path into the dataset's sidecar, also taken when the person leaves a drawer that holds an edit.
    func writeFASTQDrawerMetadata(_ metadata: FASTQDemultiplexMetadata, to targetURL: URL) throws {
        var persisted = FASTQMetadataStore.load(for: targetURL) ?? PersistedFASTQMetadata()
        persisted.demultiplexMetadata = metadata
        try FASTQMetadataStore.write(persisted, for: targetURL)
        syncDemuxConfigToController()
    }

    /// FASTQ-DRAWER-EDIT-LOST-ON-SELECT. The drawer goes, or loads another dataset, only after the person has selected
    /// something else, so an edit that waits in it is saved then, to the dataset it was made on, through Save's own
    /// path. A sheet could not offer Cancel here, since the selection has already moved. When the write fails, a sheet
    /// says that the edit was not saved and why. A drawer with no edit writes nothing.
    func keepWaitingFASTQDrawerEdit() {
        guard let unkept = keepWaitingFASTQDrawerEditReportingFailure() else { return }
        // The close sheet has said this edit was not saved. Only this step reads the mark, so Quit still asks.
        guard !fastqDrawerEditReportedByCloseSheet else { return }
        Self.presentUnkeptFASTQDrawerEdit(Self.unkeptFASTQDrawerEditAlert(unkept), view.window)
    }

    /// The keep step every way out of the drawer takes: leaving the dataset, Quit and the close of the window
    /// (FASTQ-DRAWER-EDIT-LOST-ON-QUIT). It saves a waiting edit through Save's own path and returns what could not be
    /// saved, for the caller's own sheet. It is nil when the edit was saved or none waits.
    func keepWaitingFASTQDrawerEditReportingFailure() -> UnkeptFASTQDrawerEdit? {
        guard let drawer = fastqMetadataDrawerView else { return nil }
        drawer.endCellEditing()
        guard drawer.hasWaitingEdit, let datasetURL = drawer.datasetURL else { return nil }
        do {
            try writeFASTQDrawerMetadata(drawer.currentMetadata(), to: datasetURL)
            drawer.markSettingsKept()
            fastqDrawerLogger.info("Kept the drawer's edit for \(datasetURL.lastPathComponent, privacy: .public) on leaving it")
            return nil
        } catch {
            fastqDrawerLogger.warning("Could not keep the drawer's edit for \(datasetURL.lastPathComponent, privacy: .public): \(error)")
            return UnkeptFASTQDrawerEdit(datasetURL: datasetURL, reason: error.localizedDescription, window: view.window)
        }
    }

    /// The sheet for a drawer edit that could not be saved on leaving. Tests replace it, so no test opens a real sheet.
    static var presentUnkeptFASTQDrawerEdit: @MainActor (NSAlert, NSWindow?) -> Void = { alert, window in
        guard let window else { return }
        alert.beginSheetModal(for: window)
    }

    /// The same sheet on a project window that is closing, and the close once the person has pressed OK, so the words
    /// are seen before the window goes. Tests replace it, so no test opens a real sheet.
    static var presentUnkeptFASTQDrawerEditBeforeClose: @MainActor (NSAlert, NSWindow, @escaping @MainActor () -> Void) -> Void = {
        alert, window, close in
        alert.beginSheetModal(for: window) { _ in
            Task { @MainActor in close() }
        }
    }

    static func unkeptFASTQDrawerEditAlert(_ unkept: UnkeptFASTQDrawerEdit, closingWindow: Bool = false) -> NSAlert {
        let name = unkept.name
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The FASTQ drawer\u{2019}s edits for \(name) were not saved."
        let closes = closingWindow ? " The window closes when you press OK." : ""
        let next = closingWindow ? "then open the project, select it and make the edits again." : "then select it and make the edits again."
        alert.informativeText = "\(unkept.reason) The settings saved earlier are unchanged.\(closes) Check that \(name) "
            + "is still in the project and that its folder can be written, \(next)"
        alert.addButton(withTitle: "OK")
        return alert
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
                        // The search ended, so its last progress line must not outlast the alert (W-18).
                        self?.fastqMetadataDrawerView?.updateScoutStatus("")
                        if let window = self?.view.window {
                            FailurePresenter.present(ViewerFailureReports.detectBarcodes(error, kit: kit), in: window)
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

    /// What the drawer says after a scout. The plan reaches a run through the Demux tab's Demultiplex…, which opens
    /// Demultiplex Barcodes with it, so the words name that control and promise no Run button here.
    /// After a count from the read names it says the run splits the reads by that index (UX condition 3, changed).
    static func scoutProceedWords(count: Int, source: BarcodeCountSource? = nil) -> String {
        let added = "\(count) barcode\(count == 1 ? "" : "s") added to the plan."
        guard source == .readNameIndex else { return added + " Demultiplex\u{2026} opens Demultiplex Barcodes with it." }
        return added + " Demultiplex\u{2026} opens Demultiplex Barcodes, which splits the reads by the index in their names."
    }

    /// Handles the user clicking "Proceed" in the BarcodeScoutSheet after reviewing scout results.
    /// Converts accepted detections into sample assignments and updates the drawer's plan. It starts no run, since
    /// Demultiplex… in the Demux tab opens the run.
    private func handleScoutProceed(
        acceptedDetections: [BarcodeDetection],
        scoutResult: BarcodeScoutResult,
        kit: BarcodeKitDefinition
    ) {
        let assignments = Self.scoutAssignments(acceptedDetections: acceptedDetections, scoutResult: scoutResult, kit: kit)

        // Update the drawer's demux step with sample assignments
        if let drawer = fastqMetadataDrawerView {
            drawer.updateSampleAssignments(assignments)
            drawer.applySampleAssignmentsToCurrentStep(assignments)
            drawer.updateScoutStatus(Self.scoutProceedWords(count: acceptedDetections.count, source: scoutResult.countSource))
        }

        // Sync the dashboard's primer trim settings. No run starts here, since Demultiplex… opens the run.
        syncDemuxConfigToController()

        fastqDrawerLogger.info("Scout proceed: \(acceptedDetections.count) barcodes accepted, ready for manual run")
    }

    /// The plan rows Proceed writes for the accepted barcodes. A barcode counted from the index in the read names
    /// carries its source and the header route in its metadata, so the plan's run splits by the read names and never
    /// searches the read bases for it (SWIFT condition 1, ARCH pin 6).
    static func scoutAssignments(
        acceptedDetections: [BarcodeDetection],
        scoutResult: BarcodeScoutResult,
        kit: BarcodeKitDefinition
    ) -> [FASTQSampleBarcodeAssignment] {
        let metadata = scoutResult.countSource == .readNameIndex ? FASTQSampleBarcodeAssignment.readNameIndexMetadata : [:]
        // Convert accepted detections to sample assignments.
        // For combinatorial kits, scout detection IDs are in pair format "bc1001--bc1096".
        // For fixedDual kits, scout detection IDs are single barcode IDs (no "--").
        return acceptedDetections.map { detection in
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
                        reverseSequence: revBarcode?.i7Sequence,
                        metadata: metadata
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
                reverseSequence: barcode?.i5Sequence ?? barcode?.i7Sequence,
                metadata: metadata
            )
        }
    }

    /// Syncs the drawer's primer trim configuration to the dashboard. The demux plan reaches a run only through
    /// Demultiplex…, below.
    func syncDemuxConfigToController() {
        guard let drawer = fastqMetadataDrawerView else { return }
        fastqDatasetController?.currentPrimerTrimConfiguration = drawer.currentPrimerTrimConfiguration()
    }

    /// Demultiplex… in the Demux tab: writes the plan's definition into the project and opens Demultiplex Barcodes on
    /// it, where the person presses Run (ruling ARCH-DEMUX-PLAN-CONTROL). A refusal's words go to the drawer's status
    /// line. `projectURL` and `present` are for tests, which name the project and capture the launch.
    func openDemultiplexDialog(
        for plan: DemultiplexPlan,
        kits: [BarcodeKitDefinition] = BarcodeKitRegistry.builtinKits(),
        projectURL: URL? = nil,
        present: @MainActor (FASTQDemultiplexPlanLaunch) -> Void = { launch in
            AppDelegate.shared?.showFASTQOperationsDialog(
                nil, initialCategory: FASTQOperationToolID.demultiplexBarcodes.categoryID,
                initialToolID: .demultiplexBarcodes, preferredInputURLs: launch.inputURLs, configureState: launch.configure
            )
        }
    ) {
        let datasetURL = currentFASTQDatasetURL
        do {
            let launch = try FASTQDemultiplexPlanLaunch.make(
                plan: plan, kits: kits, datasetURL: datasetURL,
                projectURL: projectURL ?? datasetURL.flatMap { ProjectTempDirectory.findProjectRoot($0) }
            )
            present(launch)
        } catch {
            fastqMetadataDrawerView?.updateScoutStatus(error.localizedDescription)
        }
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
