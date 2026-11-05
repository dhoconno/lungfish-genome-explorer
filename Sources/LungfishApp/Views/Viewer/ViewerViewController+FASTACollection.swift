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

/// The search a collection has under way and the one its Re-run repeats. Each collection holds its own, through the
/// closures the display gives it, so leaving a collection or searching from another ends none of this one's search.
/// A newer search from the same list leaves an older one running on its row. Its answer reaches the row and never the
/// pane. Only NCBI's answer or the person ends a search.
@MainActor
final class FASTACollectionBlastRun {
    var task: Task<Void, Never>?
    var operationID: UUID?
    var runID: UUID?
    var lastRequest: (sourceLabel: String, fastaRecords: [String])?

    /// Ends the search this collection has under way, for the person's Cancel.
    func cancel() {
        guard task != nil || operationID != nil else { return }
        runID = nil
        if let operationID {
            OperationCenter.shared.cancel(id: operationID)
        } else {
            task?.cancel()
        }
        task = nil
        operationID = nil
    }

    func clear(runID: UUID) {
        guard self.runID == runID else { return }
        self.runID = nil
        task = nil
        operationID = nil
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
    @discardableResult
    public func displayFASTACollection(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        durableSourceURLs: [URL] = [],
        sourceFiles: [URL] = []
    ) -> Bool {
        displayFASTACollection(
            sequences: sequences,
            annotations: annotations,
            sourceNames: [:],
            durableSourceURLs: durableSourceURLs,
            sourceFiles: sourceFiles
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
    ///   - sourceFiles: The files the sequences were read from, which must still read for the list to open. A project
    ///                  sequence has no file, so it adds none.
    /// - Returns: Whether the list opened. When it did not, the status line says why.
    @discardableResult
    public func displayFASTACollection(
        sequences: [LungfishCore.Sequence],
        annotations: [SequenceAnnotation],
        sourceNames: [UUID: String],
        durableSourceURLs: [URL] = [],
        sourceFiles: [URL] = []
    ) -> Bool {
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

        // An earlier list's way back ends here, whichever route brought this one.
        hideCollectionBackButton()

        let controller = FASTACollectionViewController()
        let blastRun = FASTACollectionBlastRun()

        controller.onBlastRequested = withBlastConsent(noun: "sequences") { [weak self, weak controller] selectedSequences in
            guard let controller else { return }
            guard selectedSequences.count <= Self.blastSequenceLimit else {
                controller.showBlastFailure("Select \(Self.blastSequenceLimit) or fewer sequences to verify with BLAST.")
                return
            }
            let fastaRecords = selectedSequences.map(Self.fastaRecord(for:))
            let sourceLabel = Self.blastSourceLabel(for: selectedSequences)
            self?.runGenericBlastVerification(
                sourceLabel: sourceLabel,
                fastaRecords: fastaRecords,
                presentingIn: controller,
                run: blastRun
            )
        }
        controller.onBlastCancelRequested = {
            blastRun.cancel()
        }
        controller.onBlastRerunRequested = withBlastConsent(noun: "sequences") { [weak self, weak controller] in
            guard let self, let controller, let lastRequest = blastRun.lastRequest else { return }
            self.runGenericBlastVerification(
                sourceLabel: lastRequest.sourceLabel,
                fastaRecords: lastRequest.fastaRecords,
                presentingIn: controller,
                run: blastRun
            )
        }
        controller.onSelectionChanged = { [weak self, weak controller] picked in
            guard let self, let controller else { return }
            self.restoreSavedBlast(on: controller, run: blastRun, picked: picked)
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

        let sequenceCount = sequences.count
        controller.onOpenSequence = { [weak self, weak controller] sequence, sequenceAnnotations in
            guard let self, let controller else { return }
            // The clear removes the list, and the lines below put the genomics chrome on for one sequence. The back
            // state keeps the list, so Back finds it as the person left it, and any search it has running goes on.
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
            self.showCollectionBackButton(returningTo: controller, sequenceCount: sequenceCount)

            self.viewerView.needsDisplay = true
            self.enhancedRulerView.needsDisplay = true
            self.headerView.needsDisplay = true
            self.updateStatusBar()
            self.scheduleDeferredRedraw()
        }

        let contents = FASTACollectionSurface.Contents(
            sequences: sequences, annotations: annotations, sourceNames: sourceNames, sourceFiles: sourceFiles
        )
        guard showFASTACollection(FASTACollectionSurface.Input(controller: controller, contents: contents)) else { return false }
        logger.info("displayFASTACollection: Showing browser with \(sequences.count) sequences")
        return true
    }

    /// Shows a list through the host. One that does not open says why in the status line, in place of what the viewer showed.
    private func showFASTACollection(_ input: FASTACollectionSurface.Input) -> Bool {
        // Hide annotation drawer so it doesn't overlap the collection view
        annotationDrawerView?.isHidden = true
        do {
            _ = try showSurface(.view(.fastaCollection), input: input, as: FASTACollectionSurface.self)
            return true
        } catch {
            logger.error("displayFASTACollection: did not open: \(error.localizedDescription, privacy: .public)")
            clearViewport(statusMessage: surfaceFailureWords("Unable to open the FASTA collection.", error))
            return false
        }
    }

    /// Says which files of a selection did not read. With none read the viewer has nothing to show, so the status line says
    /// why. With some read the list shows them, under a sheet that names what is missing from it.
    func sayWhatDidNotRead(_ unread: [(name: String, error: any Error)], anyDocumentRead: Bool) {
        guard let first = unread.first else { return }
        if !anyDocumentRead {
            clearViewport(statusMessage: surfaceFailureWords("Unable to open the FASTA collection.", first.error))
        } else if let window = view.window {
            let name = unread.count > 1 ? "\(first.name) and \(unread.count - 1) more" : first.name
            FailurePresenter.present(MainWindowFailureReports.openFile(named: name, first.error), in: window)
        }
    }

    /// Removes the FASTA collection browser and restores normal viewer components. A search the list has running goes
    /// on, since only NCBI's answer or the person ends one, so the surface has nothing to stop on its way out.
    public func hideFASTACollectionView() {
        clearSurface(ifShowing: .view(.fastaCollection))
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

    /// The name a search of `sequences` takes. A restored result takes the same name, so that Re-run BLAST repeats a search
    /// of the sequences picked under the name a send of them would give it.
    private static func blastSourceLabel(for sequences: [LungfishCore.Sequence]) -> String {
        sequences.count == 1 ? sequences[0].name : "\(sequences.count) FASTA sequences"
    }

    /// The most sequences one search from a list sends. The send refuses a pick over it, so no search of such a pick can exist,
    /// and the look-up of a saved search builds no key for one.
    static let blastSequenceLimit = 50

    private func runGenericBlastVerification(
        sourceLabel: String,
        fastaRecords: [String],
        presentingIn controller: FASTACollectionViewController,
        run blastRun: FASTACollectionBlastRun
    ) {
        guard !fastaRecords.isEmpty else {
            controller.showBlastFailure(BlastServiceError.noSequences.localizedDescription)
            return
        }
        guard fastaRecords.count <= Self.blastSequenceLimit else {
            controller.showBlastFailure("Select \(Self.blastSequenceLimit) or fewer sequences to verify with BLAST.")
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
            blastRun.lastRequest = (sourceLabel, fastaRecords)
            let runID = UUID()
            blastRun.runID = runID
            controller.savedBlastRestorer = nil
            controller.showBlastLoading(phase: .submitting, requestId: nil, subject: "Search of \(sourceLabel)")
            blastRun.operationID = opID

            let request = BlastVerificationRequest(
                taxonName: sourceLabel, taxId: 0, sequences: sequences, database: BlastDatabaseID.coreNT.rawValue, entrezQuery: nil
            )
            let runner = Self.fastaBlastRunner(plan: plan, operationID: opID, override: fastaBlastVerificationRunner)
            let progressRelay = FASTABlastProgressRelay { [weak blastRun, weak controller] fraction, message in
                // The row reads on with its list gone. A cancelled run's row refuses the update.
                guard OperationCenter.shared.update(
                    id: opID,
                    progress: fraction,
                    detail: message
                ) else { return }
                guard let blastRun, let controller, blastRun.runID == runID else { return }
                controller.showBlastLoading(
                    phase: Self.blastPhase(forFraction: fraction, message: message),
                    requestId: nil,
                    subject: "Search of \(sourceLabel)"
                )
            }

            let task = Task { [weak self, weak blastRun, weak controller] in
                do {
                    let (result, recordURL) = try await runner(
                        request,
                        { fraction, message in
                            progressRelay.report(fraction: fraction, message: message)
                        }
                    )

                    guard OperationCenter.shared.complete(
                        id: opID,
                        detail: "Results ready for \(result.readResults.count) sequence\(result.readResults.count == 1 ? "" : "s")" + BlastResultsDrawerTab.collectedRowWords(recordURL: recordURL)
                    ) else { return }
                    guard let blastRun, let controller, blastRun.runID == runID else { return }
                    blastRun.clear(runID: runID)
                    controller.showBlastResults(result, recordURL: recordURL)
                } catch let parked as BlastSubmitParked {
                    // A newer search from this list owns the pane, so an older one that parks leaves it alone.
                    let ownsThePane = blastRun?.runID == runID
                    blastRun?.clear(runID: runID)
                    await Self.parkFASTABlastRow(opID, parked, controller: ownsThePane ? controller : nil)
                    // The look-up for the sequences picked now keeps this pane current, and brings a late result onto it.
                    if ownsThePane, let self, let blastRun, let controller {
                        self.restoreSavedBlast(on: controller, run: blastRun, picked: controller.selectedSequences())
                    }
                } catch is CancellationError {
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                    blastRun?.clear(runID: runID)
                } catch {
                    let errorText = error.localizedDescription
                    guard OperationCenter.shared.fail(id: opID, detail: errorText, errorMessage: errorText) else { return }
                    guard let blastRun, let controller, blastRun.runID == runID else { return }
                    blastRun.clear(runID: runID)
                    controller.showBlastFailure(errorText)
                }
            }

            Self.setFASTABlastCancel(operationID: opID, output: plan?.request.outputURL, task: task)
            blastRun.task = task
        }
    }

    /// Looks for the saved BLAST search of the sequences picked in `controller` (FASTA-BLAST-WAITING-NOT-ON-ROW). The FASTA
    /// plan records the file the list came from and no sample, taxon or contig, so a row is that file and the IDs and bases
    /// picked, built from the same records the send reads. A waiting search or its saved result shows on the pane, and the news
    /// of a search brings a late result onto it while those sequences stay picked. A list with nothing picked or no file names
    /// no row, and a search this list has loading keeps its own pane.
    func restoreSavedBlast(on controller: FASTACollectionViewController, run: FASTACollectionBlastRun, picked: [LungfishCore.Sequence]) {
        controller.savedBlastRestorer = nil
        guard run.runID == nil else { return }
        // A pick the send refuses has no search, and formatting every base of it at each click is work for nothing.
        guard picked.count <= Self.blastSequenceLimit else { return }
        let source = fastaExportSourceURLs().first
        let records = picked.map(Self.fastaRecord(for:))
        let sequences = Self.blastSequences(from: records)
            .map { BlastSavedSearchRow.QuerySequence(id: $0.id, sequence: $0.sequence) }
        let restorer = SavedBlastSearchRestorer()
        controller.savedBlastRestorer = restorer
        restorer.savedSearchProject = { [weak self] in
            self?.blastSubmitProjectURL() ?? source.flatMap(ProjectTempDirectory.findProjectRoot)
        }
        restorer.searchPane = { [weak controller] in
            guard let controller else { return nil }
            controller.collapseSelectionDetail()
            let pane = controller.ensureBlastDrawer()
            controller.openBlastDrawerIfNeeded()
            return pane
        }
        let row = source.flatMap { BlastSavedSearchRow.fastaSelection(sequences: sequences, sourceURL: $0) }
        // A result shown here is the list's Re-run request, so Re-run BLAST repeats the sequences picked and not the last send.
        let label = Self.blastSourceLabel(for: picked)
        restorer.select(row) { [weak controller, weak run] result, recordURL in
            run?.lastRequest = (label, records)
            controller?.showBlastResults(result, recordURL: recordURL)
        }
    }

    nonisolated static func blastPhase(forProgressMessage message: String) -> BlastJobPhase {
        let lowercased = message.lowercased()
        if lowercased.contains("sending") || lowercased.contains("submitting") { return .submitting }
        if lowercased.contains("parsing") || lowercased.contains("collecting") { return .parsing }
        return .waiting
    }

    /// The advancer reports this much or more once NCBI has taken the first send, and less until then.
    nonisolated static let blastFirstSendTakenFraction = 0.20

    /// The phase the pane shows for a progress report, from the (fraction, message) the Operations row reads. Words that
    /// say sending or parsing decide as before, and any other report is waiting only once a send has gone out. Until then
    /// the search is still submitting, so the pane never says Waiting or Phase 2 for a search that nothing waits on (W-20).
    nonisolated static func blastPhase(forFraction fraction: Double, message: String) -> BlastJobPhase {
        let byWords = blastPhase(forProgressMessage: message)
        return byWords == .waiting && fraction < blastFirstSendTakenFraction ? .submitting : byWords
    }

    /// Shows a navigation bar with "Back to Collection" above the viewer content.
    private func showCollectionBackButton(returningTo controller: FASTACollectionViewController, sequenceCount: Int) {
        hideCollectionBackButton()

        // Create a thin navigation bar that sits above the viewer content
        let navBar = NSView()
        navBar.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .accessoryBarAction
        button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        button.imagePosition = .imageLeading
        button.title = "All Sequences (\(sequenceCount))"
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

        // Keep the list itself, with the person's place in it, to return to
        collectionBackController = controller
        collectionBackButton = button
        collectionNavBar = navBar
    }

    public func hideCollectionBackButton() {
        collectionNavBar?.removeFromSuperview()
        collectionNavBar = nil
        collectionBackButton = nil
        collectionBackController = nil
    }

    @objc func collectionBackButtonTapped(_ sender: Any?) {
        guard let controller = collectionBackController else { return }
        hideCollectionBackButton()
        contentMode = .genomics
        fastaCollectionSourceURLs = normalizedExistingURLs(fastaCollectionSourceURLs)
        // No contents, so nothing configures the list again, and it reads no file.
        _ = showFASTACollection(FASTACollectionSurface.Input(controller: controller, contents: nil))
    }
}
