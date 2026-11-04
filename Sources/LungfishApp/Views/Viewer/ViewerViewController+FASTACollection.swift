// ViewerViewController+FASTACollection.swift - The FASTA collection browser, its way back and its BLAST route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

private final class FASTABlastProgressRelay: @unchecked Sendable {
    @MainActor
    private let delivery: (Double, String) -> Void

    @MainActor
    init(delivery: @escaping (Double, String) -> Void) {
        self.delivery = delivery
    }

    nonisolated func report(fraction: Double, message: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.delivery(fraction, message)
            }
        }
    }
}

extension ViewerViewController {
    // MARK: - FASTA Collection Display

    /// Displays the multi-sequence FASTA collection browser in place of the
    /// normal sequence viewer.
    ///
    /// - Parameters:
    ///   - sequences: All sequences from the FASTA file.
    ///   - annotations: Associated annotations (grouped by chromosome internally).
    public func displayFASTACollection(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        durableSourceURLs: [URL] = []
    ) {
        displayFASTACollection(
            sequences: sequences,
            annotations: annotations,
            sourceNames: [:],
            durableSourceURLs: durableSourceURLs
        )
    }

    /// Displays a FASTA collection view with sequences from multiple source documents.
    ///
    /// When `sourceNames` is non-empty, the collection table shows a "Source" column
    /// indicating which file each sequence came from. The summary bar also reflects
    /// the number of source files.
    ///
    /// - Parameters:
    ///   - sequences: Combined sequences from all selected documents.
    ///   - annotations: Combined annotations from all selected documents.
    ///   - sourceNames: Maps sequence IDs to source file names. Pass empty for
    ///                  single-document display.
    public func displayFASTACollection(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        sourceNames: [UUID: String],
        durableSourceURLs: [URL] = []
    ) {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideAlignmentTreeBundleViews()
        contentMode = .genomics

        let capturedSourceURLs = normalizedExistingURLs(
            durableSourceURLs.isEmpty ? fastaExportSourceURLs() : durableSourceURLs
        )
        fastaCollectionSourceURLs = capturedSourceURLs

        let controller = FASTACollectionViewController()
        addChild(controller)

        // Hide annotation drawer so it doesn't overlap the collection view
        annotationDrawerView?.isHidden = true

        let dashView = controller.view
        dashView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashView)

        NSLayoutConstraint.activate([
            dashView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            dashView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dashView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.onBlastRequested = withBlastConsent(noun: "sequences") { [weak self, weak controller] selectedSequences in
            guard let controller else { return }
            let fastaRecords = selectedSequences.map(Self.fastaRecord(for:))
            let sourceLabel = selectedSequences.count == 1
                ? selectedSequences[0].name
                : "\(selectedSequences.count) FASTA sequences"
            self?.runGenericBlastVerification(
                sourceLabel: sourceLabel,
                fastaRecords: fastaRecords,
                presentingIn: controller
            )
        }
        controller.onBlastCancelRequested = { [weak self] in
            self?.cancelActiveFASTABlast()
        }
        controller.onBlastRerunRequested = withBlastConsent(noun: "sequences") { [weak self, weak controller] in
            guard let self, let controller, let lastRequest = self.lastFASTABlastRequest else { return }
            self.runGenericBlastVerification(
                sourceLabel: lastRequest.sourceLabel,
                fastaRecords: lastRequest.fastaRecords,
                presentingIn: controller
            )
        }
        controller.onExtractSequenceRequested = { [weak self] selectedSequences in
            self?.presentFASTASequenceExtractionDialog(
                records: selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.bundleName(for: selectedSequences)
            )
        }
        controller.onExtractSequenceWithAnnotationsRequested = { [weak self] selectedSequences, annotationsByRecord in
            self?.presentFASTASequenceExtractionDialog(
                records: selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.bundleName(for: selectedSequences),
                annotationsByRecord: annotationsByRecord
            )
        }
        controller.onExportRequested = { [weak self] selectedSequences in
            self?.exportFASTARecords(
                selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.fastaExportName(for: selectedSequences)
            )
        }
        controller.onCreateBundleRequested = { [weak self] selectedSequences in
            self?.createReferenceBundle(
                from: selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.bundleName(for: selectedSequences)
            )
        }
        controller.onCreateBundleWithAnnotationsRequested = { [weak self] selectedSequences, annotationsByRecord in
            self?.createReferenceBundle(
                from: selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.bundleName(for: selectedSequences),
                annotationsByRecord: annotationsByRecord
            )
        }
        controller.onAlignWithMAFFTRequested = { [weak self] selectedSequences in
            self?.presentFASTAOperationDialog(
                records: selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.bundleName(for: selectedSequences),
                initialCategory: .alignment,
                initialToolID: .mafft
            )
        }
        controller.onRunOperationRequested = { [weak self] selectedSequences in
            self?.presentFASTAOperationDialog(
                records: selectedSequences.map(Self.fastaRecord(for:)),
                suggestedName: Self.bundleName(for: selectedSequences)
            )
        }

        controller.configure(
            sequences: sequences,
            annotations: annotations,
            sourceNames: sourceNames
        )
        // Store collection data so we can return to it via the back button
        let allSequences = sequences
        let allAnnotations = annotations
        let allSourceNames = sourceNames

        controller.onOpenSequence = { [weak self] sequence, sequenceAnnotations in
            guard let self else { return }
            self.hideFASTACollectionView()
            self.clearBundleDisplay()
            self.contentMode = .genomics

            // Set up the viewer directly with the selected sequence
            self.view.layoutSubtreeIfNeeded()
            let effectiveWidth = max(800, Int(self.viewerView.bounds.width))

            self.referenceFrame = ReferenceFrame(
                chromosome: sequence.name,
                start: 0,
                end: Double(min(sequence.length, 10000)),
                pixelWidth: effectiveWidth,
                sequenceLength: sequence.length
            )

            self.viewerView.setSequence(sequence)
            self.viewerView.setAnnotations(sequenceAnnotations)

            let trackNames = [sequence.name]
                + (sequenceAnnotations.isEmpty ? [] : ["Annotations"])
            self.headerView.setTrackNames(trackNames)
            self.enhancedRulerView.referenceFrame = self.referenceFrame

            // Restore viewer components
            self.enhancedRulerView.isHidden = false
            self.viewerView.isHidden = false
            self.headerView.isHidden = false
            self.statusBar.isHidden = false
            self.geneTabBarView.isHidden = true

            // Add "Back to Collection" button above the viewer
            self.showCollectionBackButton(
                sequences: allSequences,
                annotations: allAnnotations,
                sourceNames: allSourceNames,
                durableSourceURLs: capturedSourceURLs
            )

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
            self.updateStatusBar()
            self.scheduleDeferredRedraw()
        }

        fastaCollectionController = controller

        // Hide normal genomic viewer components
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        logger.info("displayFASTACollection: Showing browser with \(sequences.count) sequences")
    }

    /// Removes the FASTA collection browser and restores normal viewer components.
    public func hideFASTACollectionView() {
        guard let controller = fastaCollectionController else { return }
        cancelActiveFASTABlast()
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        fastaCollectionController = nil

        // Restore normal viewer components
        enhancedRulerView.isHidden = false
        viewerView.isHidden = false
        statusBar.isHidden = false
        revealAnnotationDrawerUnlessNativeBundleInstalled()
    }

    private static func fastaRecord(for sequence: LungfishCore.Sequence) -> String {
        FASTASelectionDetailFormatter.record(for: sequence)
    }

    private static func fastaExportName(for sequences: [LungfishCore.Sequence]) -> String {
        if sequences.count == 1, let sequence = sequences.first {
            return "\(sequence.name).fa"
        }
        return "selected-sequences.fa"
    }

    private static func bundleName(for sequences: [LungfishCore.Sequence]) -> String {
        if sequences.count == 1, let sequence = sequences.first {
            return sequence.name
        }
        return "selected-sequences"
    }

    private func runGenericBlastVerification(
        sourceLabel: String,
        fastaRecords: [String],
        presentingIn controller: FASTACollectionViewController
    ) {
        guard !fastaRecords.isEmpty else {
            controller.showBlastFailure(BlastServiceError.noSequences.localizedDescription)
            return
        }
        guard fastaRecords.count <= 50 else {
            controller.showBlastFailure("Select 50 or fewer sequences to verify with BLAST.")
            return
        }

        let sequences = Self.blastSequences(from: fastaRecords)
        guard !sequences.isEmpty else {
            controller.showBlastFailure(BlastServiceError.noSequences.localizedDescription)
            return
        }

        guard let plan = Self.blastSubmitPlan(window: view.window, failure: { controller.showBlastFailure($0) }, {
            try fastaBlastSubmitPlan(sourceLabel: sourceLabel, sequences: sequences)
        }) else { return }
        Self.beginGenericBlastVerificationOperation(sourceLabel: sourceLabel, cliCommand: plan?.cliCommand) { opID in
            cancelActiveFASTABlast()
            lastFASTABlastRequest = (sourceLabel, fastaRecords)
            let runID = UUID()
            activeFASTABlastRunID = runID
            controller.showBlastLoading(phase: .submitting, requestId: nil)
            activeFASTABlastOperationID = opID

            let request = BlastVerificationRequest(
                taxonName: sourceLabel, taxId: 0, sequences: sequences, database: BlastDatabaseID.coreNT.rawValue, entrezQuery: nil
            )
            let runner = Self.fastaBlastRunner(plan: plan, operationID: opID, override: fastaBlastVerificationRunner)
            let progressRelay = FASTABlastProgressRelay { [weak self, weak controller] fraction, message in
                guard let self, let controller,
                      self.activeFASTABlastRunID == runID else { return }
                guard OperationCenter.shared.update(
                    id: opID,
                    progress: fraction,
                    detail: message
                ) else { return }
                controller.showBlastLoading(
                    phase: Self.blastPhase(forProgressMessage: message),
                    requestId: nil
                )
            }

            let task = Task { [weak self, weak controller] in
                do {
                    let (result, recordURL) = try await runner(
                        request,
                        { fraction, message in
                            progressRelay.report(fraction: fraction, message: message)
                        }
                    )

                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Results ready for \(result.readResults.count) sequence\(result.readResults.count == 1 ? "" : "s")"
                    ) else { return }
                    guard let self, let controller,
                          self.activeFASTABlastRunID == runID else { return }
                    self.clearActiveFASTABlast(runID: runID)
                    controller.showBlastResults(result, recordURL: recordURL)
                } catch let parked as BlastSubmitParked {
                    self?.clearActiveFASTABlast(runID: runID)
                    await Self.parkFASTABlastRow(opID, parked, controller: controller)
                } catch is CancellationError {
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                    self?.clearActiveFASTABlast(runID: runID)
                } catch {
                    let errorText = error.localizedDescription
                    guard OperationCenter.shared.fail(id: opID, detail: errorText, errorMessage: errorText) else { return }
                    guard let self, let controller,
                          self.activeFASTABlastRunID == runID else { return }
                    self.clearActiveFASTABlast(runID: runID)
                    controller.showBlastFailure(errorText)
                }
            }

            Self.setFASTABlastCancel(operationID: opID, output: plan?.request.outputURL, task: task)
            activeFASTABlastTask = task
        }
    }

    private func cancelActiveFASTABlast() {
        guard activeFASTABlastTask != nil || activeFASTABlastOperationID != nil else { return }
        activeFASTABlastRunID = nil
        if let operationID = activeFASTABlastOperationID {
            OperationCenter.shared.cancel(id: operationID)
        } else {
            activeFASTABlastTask?.cancel()
        }
        activeFASTABlastTask = nil
        activeFASTABlastOperationID = nil
    }

    private func clearActiveFASTABlast(runID: UUID) {
        guard activeFASTABlastRunID == runID else { return }
        activeFASTABlastRunID = nil
        activeFASTABlastTask = nil
        activeFASTABlastOperationID = nil
    }

    nonisolated private static func blastPhase(forProgressMessage message: String) -> BlastJobPhase {
        let lowercased = message.lowercased()
        if lowercased.contains("waiting") { return .waiting }
        if lowercased.contains("parsing") { return .parsing }
        return .submitting
    }

    /// Shows a navigation bar with "Back to Collection" above the viewer content.
    private func showCollectionBackButton(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        sourceNames: [UUID: String] = [:],
        durableSourceURLs: [URL] = []
    ) {
        hideCollectionBackButton()

        // Create a thin navigation bar that sits above the viewer content
        let navBar = NSView()
        navBar.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        button.imagePosition = .imageLeading
        button.title = "All Sequences (\(sequences.count))"
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = #selector(collectionBackButtonTapped(_:))

        // Separator line at bottom of nav bar
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        navBar.addSubview(button)
        navBar.addSubview(separator)
        view.addSubview(navBar)

        // Position nav bar at the very top of the safe area, pushing content down
        // by adjusting the enhanced ruler's top constraint
        NSLayoutConstraint.activate([
            navBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            navBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            navBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            navBar.heightAnchor.constraint(equalToConstant: 28),

            button.leadingAnchor.constraint(equalTo: navBar.leadingAnchor, constant: 6),
            button.centerYAnchor.constraint(equalTo: navBar.centerYAnchor),

            separator.leadingAnchor.constraint(equalTo: navBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: navBar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: navBar.bottomAnchor),
        ])

        // Store the collection data so we can return to it
        collectionBackSequences = sequences
        collectionBackAnnotations = annotations
        collectionBackSourceNames = sourceNames
        collectionBackSourceURLs = durableSourceURLs
        collectionBackButton = button
        collectionNavBar = navBar
    }

    public func hideCollectionBackButton() {
        collectionNavBar?.removeFromSuperview()
        collectionNavBar = nil
        collectionBackButton = nil
        collectionBackSequences = nil
        collectionBackAnnotations = nil
        collectionBackSourceNames = nil
        collectionBackSourceURLs = nil
    }

    @objc func collectionBackButtonTapped(_ sender: Any?) {
        guard let sequences = collectionBackSequences,
              let annotations = collectionBackAnnotations else { return }
        let sourceNames = collectionBackSourceNames ?? [:]
        let durableSourceURLs = collectionBackSourceURLs ?? []
        hideCollectionBackButton()
        displayFASTACollection(
            sequences: sequences,
            annotations: annotations,
            sourceNames: sourceNames,
            durableSourceURLs: durableSourceURLs
        )
    }
}
