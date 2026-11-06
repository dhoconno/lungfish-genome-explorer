import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishTwelveSUI
import LungfishWorkflow

extension ViewerViewController {
    /// The installed 12S result viewer, read from the surface host.
    var twelveSAmpliconResultViewController: TwelveSAmpliconResultViewController? {
        surfaceHost.activeViewport?.viewController as? TwelveSAmpliconResultViewController
    }

    /// Shows `result` through the surface host and returns its installed viewer,
    /// or throws the reason it is not installed. `onWillDeactivate` runs when the
    /// host later removes this viewer for another kind.
    @discardableResult
    func displayTwelveSAmpliconResult(
        _ result: TwelveSAmpliconResultBundleData,
        onWillDeactivate: (@MainActor () -> Void)? = nil
    ) throws -> TwelveSAmpliconResultViewController {
        // The hide list below reaches hideTwelveSAmpliconResultView, which must leave
        // an installed 12S viewer for the host's show to replace (HOST-ARCH R4).
        surfaceKindBeingDisplayed = .bundle(.twelveSResult)
        defer { surfaceKindBeingDisplayed = nil }
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideMHCReferenceBundleView()
        hideGenotypeResultView()
        hideAlignmentTreeBundleViews()
        clearBundleDisplay()
        hideCollectionBackButton()
        hideBundleBackNavigationButton()
        hideProgress()
        contentMode = .metagenomics
        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let surface = try showSurface(.bundle(.twelveSResult), input: result, as: TwelveSSurface.self)
        surface.onWillDeactivate = onWillDeactivate
        return surface.controller
    }

    /// Hides the 12S result viewer, a shim that other display routes call until the
    /// hide list goes in Phase 3.2.
    func hideTwelveSAmpliconResultView() {
        clearSurface(ifShowing: .bundle(.twelveSResult))
    }

    /// Sends the unresolved sequences the 12S viewer asks to verify to BLAST. The
    /// surface factory in ViewerViewController+Surfaces.swift calls it for each new
    /// viewer.
    func wireTwelveSUnresolvedBlast(_ controller: TwelveSAmpliconResultViewController) {
        controller.savedBlastSearchProject = { [weak self] in self?.blastSubmitProjectURL() }
        controller.onUnresolvedBlastRequested = withBlastConsent(noun: "sequences") { [weak self, weak controller] request in
            guard let controller else { return }
            let minimumReads = max(0, request.minimumReads)
            let exportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-12s-blast-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("unresolved-min\(minimumReads).fasta")
            let arguments = Self.twelveSUnresolvedExportArguments(
                bundleURL: request.bundleURL,
                minimumReads: minimumReads,
                exportURL: exportURL,
                sequenceIDs: request.sequences.map(\.sequenceID)
            )
            self?.launchTwelveSUnresolvedBlastSubmit(
                bundleURL: request.bundleURL, exportURL: exportURL, arguments: arguments,
                heldRows: Self.twelveSHeldRows(of: request), controller: controller
            )
        }
    }

    /// The rows a 12S BLAST holds against the export it runs, which are the requested rows the export keeps. The
    /// export drops the rows under the minimum reads (`TwelveSUnresolvedFastaExportWorkflow`), so these drop them too.
    nonisolated static func twelveSHeldRows(of request: TwelveSUnresolvedBlastRequest) -> [TwelveSUnresolvedSequence] {
        let minimumReads = max(0, request.minimumReads)
        return request.sequences.filter { $0.readCount >= minimumReads }
    }

    /// The `lungfish-cli fastq 12s-export-unresolved` argv that the BLAST
    /// preparation runs. It writes the unresolved sequences with at least
    /// `minimumReads` identical reads to a FASTA file at `exportURL`, chimera
    /// candidates included and limited to `sequenceIDs` when that list is not
    /// empty.
    nonisolated static func twelveSUnresolvedExportArguments(
        bundleURL: URL,
        minimumReads: Int,
        exportURL: URL,
        sequenceIDs: [String]
    ) -> [String] {
        var arguments = [
            "fastq", "12s-export-unresolved",
            "--bundle", bundleURL.path,
            "--min-reads", String(minimumReads),
            "--output", exportURL.path,
            "--include-chimera-candidates",
            "--force",
        ]
        for sequenceID in sequenceIDs {
            arguments += ["--sequence-id", sequenceID]
        }
        return arguments
    }

    /// The prefix of the log line that names the export step's command.
    static let twelveSExportLogPrefix = "Export step: "

    /// The 12S unresolved sequences' search on `blast submit` (2.12 lane 12.09, on the recipe of lane 12.08).
    /// With no project it shows the `No Project Open` refusal and begins no row. Otherwise the row begins at
    /// once with no command and logs the export step, so Cancel reaches it while `prepare` runs
    /// `lungfish-cli fastq 12s-export-unresolved`, checks the export's provenance and reads its FASTA, and
    /// Cancel then stops that export's whole process tree. Once the sequences are read, the plan they make
    /// gives the command, the row takes it through `setCommand` and the leaf starts at once. The export stays
    /// the source of the query, the sequences it wrote, and the record's source result is the 12S result
    /// bundle they came from. A Cancel during the preparation ends the row cancelled and starts no search,
    /// and a preparation that fails fails the row and the drawer. `drawer`, `runner` and `prepare` are
    /// seams for tests. The result is the task that prepares and launches, nil when no row began.
    @discardableResult
    func launchTwelveSUnresolvedBlastSubmit(
        bundleURL: URL,
        exportURL: URL,
        arguments: [String],
        heldRows: [TwelveSUnresolvedSequence],
        controller: TwelveSAmpliconResultViewController?,
        drawer: BlastSubmitDrawer? = nil,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner(),
        prepare: @escaping TwelveSBlastQuery.Preparer = TwelveSBlastQuery.prepare
    ) -> Task<Void, Never>? {
        let window = view.window
        guard let projectURL = blastSubmitProjectURL() ?? ProjectTempDirectory.findProjectRoot(bundleURL) else {
            Self.refuseBlastWithoutProject(window: window)
            return nil
        }
        let run = BlastDrawerRun()
        let drawer = drawer ?? BlastSubmitDrawer(
            loading: { controller?.showBlastLoading(phase: $0, requestId: nil) },
            results: {
                controller?.onUnresolvedBlastCancelRequested = nil
                controller?.landBlastResults($0, recordURL: $1, run: run.id)
            },
            failure: {
                controller?.onUnresolvedBlastCancelRequested = nil
                controller?.showBlastFailure($0)
            },
            began: { run.id = $0 },
            waiting: { controller?.showBlastWaiting($0) }
        )
        var preparation: Task<Void, Never>?
        // 1. The row begins with no command. 2. The sequences are exported. 3. The row takes the plan's command.
        Self.beginTwelveSUnresolvedBlastOperation(cliArguments: arguments) { opID in
            drawer.loading(.submitting)
            controller?.trackBlastRun(operationID: opID)
            controller?.onUnresolvedBlastCancelRequested = { OperationCenter.shared.cancel(id: opID) }
            let cancellation = LungfishCLIRunner.CancellationHandle()
            let task = Task { @MainActor in
                do {
                    let sequences = try await prepare(arguments, exportURL, cancellation)
                    // A Cancel moves the row to cancelling at once but stops this task a moment later, so the
                    // row is asked as well as the task.
                    try Task.checkCancellation()
                    guard OperationCenter.shared.items.first(where: { $0.id == opID })?.state == .running else {
                        throw CancellationError()
                    }
                    // The export read the bundle on disk when it ran, so a bundle replaced after this viewer opened
                    // gives the new bundle's sequences under the same IDs. Nothing is sent unless the query is the rows.
                    guard Self.twelveSBlastQuery(sequences, isHeldRows: heldRows) else {
                        throw TwelveSBlastQuery.ResultChangedOnDisk()
                    }
                    let plan = try Self.twelveSUnresolvedBlastSubmitPlan(
                        sequences: sequences, bundleURL: bundleURL, projectURL: projectURL
                    )
                    OperationCenter.shared.setCommand(id: opID, command: plan.cliCommand)
                    let count = sequences.count
                    // No await sits between the checks above and the cancel callback this call replaces.
                    Self.launchBlastSubmit(plan, operationID: opID, runner: runner, drawer: drawer) { _ in
                        "BLAST results ready for \(count) unresolved sequence\(count == 1 ? "" : "s")"
                    }
                } catch is CancellationError {
                    controller?.onUnresolvedBlastCancelRequested = nil
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                } catch LungfishCLIRunner.RunError.cancelled {
                    controller?.onUnresolvedBlastCancelRequested = nil
                    OperationCenter.shared.log(id: opID, level: .info, message: "12S BLAST preparation cancelled")
                    OperationCenter.shared.acknowledgeCancellation(id: opID)
                } catch {
                    controller?.onUnresolvedBlastCancelRequested = nil
                    let words = error.localizedDescription
                    guard OperationCenter.shared.fail(id: opID, detail: words, errorMessage: words) else { return }
                    drawer.failure(words)
                }
            }
            OperationCenter.shared.setCancelCallback(for: opID) {
                task.cancel()
                cancellation.cancel()
            }
            preparation = task
        }
        return preparation
    }

    /// The search of the 12S unresolved sequences on `blast submit` (2.12 lane 12.09). The query holds every
    /// sequence the export wrote, as the in-process route sent them, labelled `12S unresolved sequences` with
    /// no taxon, since the sequences matched no target. The record names the 12S result bundle they came from.
    /// It names no sample and no contig, since the sequences are pooled across samples and the query's headers
    /// name each one. The search's folder sits under the project's `blast-verifications/`, never in the bundle.
    nonisolated static func twelveSUnresolvedBlastSubmitPlan(
        sequences: [(id: String, sequence: String)],
        bundleURL: URL,
        projectURL: URL?,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        try BlastSubmitPlan.make(
            sequences: sequences, label: "12S unresolved sequences", projectURL: projectURL,
            sourceResultURL: bundleURL, outputParentURL: projectURL, date: date
        )
    }

    /// Whether a prepared query is exactly the held rows, each ID with its sequence, in any order. A held row with
    /// no sequence is left out, since the export writes it and the FASTA reader drops it, which also trims the
    /// sequence it keeps. The case of a sequence and its letters are compared as they are.
    nonisolated static func twelveSBlastQuery(
        _ query: [(id: String, sequence: String)], isHeldRows heldRows: [TwelveSUnresolvedSequence]
    ) -> Bool {
        let sent = query.map { BlastSavedSearchRow.QuerySequence(id: $0.id, sequence: $0.sequence) }
        let held = heldRows.compactMap { row -> BlastSavedSearchRow.QuerySequence? in
            let sequence = row.sequence.trimmingCharacters(in: .whitespacesAndNewlines)
            return sequence.isEmpty ? nil : BlastSavedSearchRow.QuerySequence(id: row.sequenceID, sequence: sequence)
        }
        return sent.sorted() == held.sorted()
    }

    /// The query a 12S unresolved-sequence BLAST sends, prepared off the main actor (2.12 lane 12.09).
    enum TwelveSBlastQuery {
        /// The preparation a BLAST runs, ``prepare`` or a test's stand-in. It runs the export `arguments` name,
        /// which writes the FASTA at `exportURL`, and returns the sequences it holds. `cancellation` stops the
        /// export's process tree.
        typealias Preparer = @Sendable (
            _ arguments: [String], _ exportURL: URL, _ cancellation: LungfishCLIRunner.CancellationHandle
        ) async throws -> [(id: String, sequence: String)]

        /// The query the export wrote is not the rows on screen, which happens when another run replaced the 12S
        /// result on disk after the viewer opened it. The row fails with these words and nothing is sent.
        struct ResultChangedOnDisk: LocalizedError {
            var errorDescription: String? {
                "This 12S result changed on disk after it opened, so the rows on screen are not the sequences in the result. Nothing was sent to NCBI. Select another item in the sidebar, select this result again, and run BLAST again."
            }
        }

        /// Runs `lungfish-cli fastq 12s-export-unresolved`, checks that its provenance names the FASTA and reads
        /// the sequences, as the in-process route does. The staging folder is removed when the preparation ends.
        @concurrent static func prepare(
            arguments: [String],
            exportURL: URL,
            cancellation: LungfishCLIRunner.CancellationHandle
        ) async throws -> [(id: String, sequence: String)] {
            defer { try? ViewerViewController.removeTwelveSBlastPreparationArtifacts(for: exportURL) }
            try FileManager.default.createDirectory(
                at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            _ = try await LungfishCLIRunner.run(arguments: arguments, cancellation: cancellation)
            try ViewerViewController.verifyTwelveSBlastPreparationProvenance(
                sidecarURL: ProvenanceRecorder.fileSidecarURL(for: exportURL),
                outputURL: exportURL
            )
            let sequences = try ViewerViewController.twelveSBlastSequences(fromFasta: exportURL)
            guard !sequences.isEmpty else { throw BlastServiceError.noSequences }
            return sequences
        }
    }

    /// Registers the 12S unresolved-sequence BLAST row and, only when it
    /// starts, calls `launch` with the operation ID. The row locks no bundle.
    ///
    /// `cliArguments` is the argv the run executes first, which
    /// ``twelveSUnresolvedExportArguments(bundleURL:minimumReads:exportURL:sequenceIDs:)``
    /// builds. The row's log records it as the
    /// `lungfish-cli fastq 12s-export-unresolved` command it is, the step that
    /// makes the query. `cliCommand` is the `lungfish-cli blast submit` command
    /// that runs the search (``BlastSubmitPlan/cliCommand``), nil on the row
    /// ``launchTwelveSUnresolvedBlastSubmit(bundleURL:exportURL:arguments:heldRows:controller:drawer:runner:prepare:)``
    /// begins before the query exists.
    @discardableResult
    static func beginTwelveSUnresolvedBlastOperation(
        cliArguments: [String],
        cliCommand: String? = nil,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let exportCommand = OperationCenter.buildCLICommand(
            subcommand: "fastq 12s-export-unresolved",
            args: Array(cliArguments.dropFirst(2))
        )
        let result = reporter.begin(
            title: "BLAST 12S Unresolved",
            detail: "Preparing unresolved sequence FASTA...",
            operationType: .blastVerification,
            cliCommand: cliCommand
        )
        switch result {
        case .started(let operationID):
            reporter.log(id: operationID, level: .info, message: "\(Self.twelveSExportLogPrefix)\(exportCommand)")
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    private nonisolated static func twelveSBlastSequences(fromFasta fastaURL: URL) throws -> [(id: String, sequence: String)] {
        let text = try String(contentsOf: fastaURL, encoding: .utf8)
        var records: [(id: String, sequence: String)] = []
        var currentID: String?
        var currentSequence = ""
        func flush() {
            guard let currentID else { return }
            let sequence = currentSequence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sequence.isEmpty else { return }
            records.append((id: currentID, sequence: sequence))
        }
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix(">") {
                flush()
                currentID = String(line.dropFirst().split(separator: " ").first ?? "")
                currentSequence = ""
            } else {
                currentSequence += line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        flush()
        return records
    }

    nonisolated static func removeTwelveSBlastPreparationArtifacts(for exportURL: URL) throws {
        let stagingDirectory = exportURL.deletingLastPathComponent()
        guard stagingDirectory.lastPathComponent.hasPrefix("lungfish-12s-blast-"),
              FileManager.default.fileExists(atPath: stagingDirectory.path) else {
            return
        }
        try FileManager.default.removeItem(at: stagingDirectory)
    }

    private nonisolated static func verifyTwelveSBlastPreparationProvenance(
        sidecarURL: URL,
        outputURL: URL
    ) throws {
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL),
              envelope.toolName == CLICommandIdentity.executableName,
              envelope.workflowName == "lungfish fastq 12s-export-unresolved",
              envelope.exitStatus == 0,
              !envelope.argv.isEmpty else {
            throw LocalWorkflowExecutionError.invalidProvenance(sidecarURL.path)
        }
        let outputPath = outputURL.standardizedFileURL.path
        let outputPaths = Set(
            (envelope.outputs + envelope.steps.flatMap(\.outputs))
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        guard outputPaths.contains(outputPath) else {
            throw LocalWorkflowExecutionError.invalidProvenance(sidecarURL.path)
        }
    }
}
