// ViewerViewController+FASTQDrawer.swift - FASTQ metadata drawer integration
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import os.log

private let fastqDrawerLogger = Logger(subsystem: "com.lungfish.browser", category: "ViewerFASTQDrawer")
private let fastqDrawerHeight: CGFloat = 360

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
        fastqDrawerLogger.info("Starting barcode scout for \(fastqURL.lastPathComponent, privacy: .public) with kit \(step.barcodeKitID, privacy: .public)")

        // Update drawer status to show scouting is in progress
        drawer.updateScoutStatus("Scouting barcodes...")

        Task.detached { [weak self] in
            do {
                let result = try await pipeline.scout(
                    inputURL: fastqURL,
                    kit: kit,
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
                        guard let self else { return }
                        fastqDrawerLogger.error("Barcode scout failed: \(error)")
                        let alert = NSAlert()
                        alert.messageText = "Barcode Detection Failed"
                        alert.informativeText = error.localizedDescription
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        }
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
        }

        // Sync to the operations panel and trigger the run
        syncDemuxConfigToController()
        if var config = fastqDatasetController?.currentDemuxConfig {
            config.sampleAssignments = assignments
            fastqDatasetController?.currentDemuxConfig = config
        }

        // Auto-trigger the run
        fastqDatasetController?.triggerCurrentOperationRun()

        fastqDrawerLogger.info("Scout proceed: \(acceptedDetections.count) barcodes accepted, triggering full demux")
    }

    /// Syncs the drawer's first demux step to the operations panel as the current config.
    func syncDemuxConfigToController() {
        guard let drawer = fastqMetadataDrawerView else { return }
        let plan = drawer.currentDemuxPlan()
        let firstStep = plan.steps.sorted(by: { $0.ordinal < $1.ordinal }).first
        fastqDatasetController?.currentDemuxConfig = firstStep
    }

    /// Opens the metadata drawer and selects the Demux Setup tab.
    func openDemuxSetupDrawer() {
        if fastqMetadataDrawerView == nil {
            configureFASTQMetadataDrawer()
        }
        if !isFASTQMetadataDrawerOpen {
            toggleFASTQMetadataDrawer()
        }
        fastqMetadataDrawerView?.selectDemuxSetupTab()
    }

    // MARK: - Drag-to-Resize

    public func fastqMetadataDrawerDidDragDivider(_ drawer: FASTQMetadataDrawerView, deltaY: CGFloat) {
        guard let heightConstraint = fastqMetadataDrawerHeightConstraint else { return }
        let maxHeight = view.bounds.height * 0.7
        let newHeight = max(150, min(maxHeight, heightConstraint.constant + deltaY))
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

extension ViewerViewController {
    private static var fastqMetadataDrawerViewKey: UInt8 = 0
    private static var fastqMetadataDrawerBottomKey: UInt8 = 0
    private static var fastqMetadataDrawerHeightKey: UInt8 = 0
    private static var fastqMetadataDrawerOpenKey: UInt8 = 0
    private static var fastqDashboardViewKey: UInt8 = 0
    private static var fastqDashboardBottomKey: UInt8 = 0
    private static var currentFASTQDatasetURLKey: UInt8 = 0
    private static var fastqDrawerHeightSaveWorkItemKey: UInt8 = 0

    var fastqMetadataDrawerView: FASTQMetadataDrawerView? {
        get { objc_getAssociatedObject(self, &Self.fastqMetadataDrawerViewKey) as? FASTQMetadataDrawerView }
        set { objc_setAssociatedObject(self, &Self.fastqMetadataDrawerViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var fastqMetadataDrawerBottomConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.fastqMetadataDrawerBottomKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.fastqMetadataDrawerBottomKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var fastqMetadataDrawerHeightConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.fastqMetadataDrawerHeightKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.fastqMetadataDrawerHeightKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var isFASTQMetadataDrawerOpen: Bool {
        get { (objc_getAssociatedObject(self, &Self.fastqMetadataDrawerOpenKey) as? NSNumber)?.boolValue ?? false }
        set { objc_setAssociatedObject(self, &Self.fastqMetadataDrawerOpenKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var fastqDashboardView: NSView? {
        get { objc_getAssociatedObject(self, &Self.fastqDashboardViewKey) as? NSView }
        set { objc_setAssociatedObject(self, &Self.fastqDashboardViewKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var fastqDashboardBottomConstraint: NSLayoutConstraint? {
        get { objc_getAssociatedObject(self, &Self.fastqDashboardBottomKey) as? NSLayoutConstraint }
        set { objc_setAssociatedObject(self, &Self.fastqDashboardBottomKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var currentFASTQDatasetURL: URL? {
        get { objc_getAssociatedObject(self, &Self.currentFASTQDatasetURLKey) as? URL }
        set { objc_setAssociatedObject(self, &Self.currentFASTQDatasetURLKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    var _fastqDrawerHeightSaveWorkItem: DispatchWorkItem? {
        get { objc_getAssociatedObject(self, &Self.fastqDrawerHeightSaveWorkItemKey) as? DispatchWorkItem }
        set { objc_setAssociatedObject(self, &Self.fastqDrawerHeightSaveWorkItemKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
