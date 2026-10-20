import AppKit
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishTwelveSUI
import LungfishWorkflow

extension ViewerViewController {
    @discardableResult
    func displayTwelveSAmpliconResult(_ result: TwelveSAmpliconResultBundleData) -> TwelveSAmpliconResultViewController {
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
        hideMHCReferenceBundleView()
        hideGenotypeResultView()
        hideAlignmentTreeBundleViews()
        clearBundleDisplay()
        hideCollectionBackButton()
        hideBundleBackNavigationButton()
        hideProgress()
        contentMode = .metagenomics

        let controller = TwelveSAmpliconResultViewController()
        addChild(controller)
        controller.onUnresolvedBlastRequested = { [weak self, weak controller] request in
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
                bundleURL: request.bundleURL, exportURL: exportURL, arguments: arguments, controller: controller
            )
        }

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let resultView = controller.view
        resultView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultView)
        NSLayoutConstraint.activate([
            resultView.topAnchor.constraint(equalTo: view.topAnchor),
            resultView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result)

        // Wire the multi-sample picker (reusing the NAO-MGS / NVD idiom). Each
        // entry's metric is the sample's exact-match read count.
        let sampleEntries = result.samples.map { sample in
            TwelveSSampleEntry(
                id: sample.sampleID,
                displayName: sample.displayName,
                exactReads: sample.exactMatchReads
            )
        }
        let pickerState = ClassifierSamplePickerState(allSamples: Set(sampleEntries.map(\.id)))
        controller.configureSamples(sampleEntries, state: pickerState)

        twelveSAmpliconResultViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        return controller
    }

    func hideTwelveSAmpliconResultView() {
        guard let controller = twelveSAmpliconResultViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        twelveSAmpliconResultViewController = nil

        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = (geneTabBarView?.selectedGeneRegion == nil)
        revealAnnotationDrawerUnlessNativeBundleInstalled()
        fastqMetadataDrawerView?.isHidden = false
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
        let drawer = drawer ?? BlastSubmitDrawer(
            loading: { controller?.showBlastLoading(phase: $0, requestId: nil) },
            results: {
                controller?.onUnresolvedBlastCancelRequested = nil
                controller?.showBlastResults($0, recordURL: $1)
            },
            failure: {
                controller?.onUnresolvedBlastCancelRequested = nil
                controller?.showBlastFailure($0)
            }
        )
        var preparation: Task<Void, Never>?
        // 1. The row begins with no command. 2. The sequences are exported. 3. The row takes the plan's command.
        Self.beginTwelveSUnresolvedBlastOperation(cliArguments: arguments) { opID in
            drawer.loading(.submitting)
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

    /// The query a 12S unresolved-sequence BLAST sends, prepared off the main actor (2.12 lane 12.09).
    enum TwelveSBlastQuery {
        /// The preparation a BLAST runs, ``prepare`` or a test's stand-in. It runs the export `arguments` name,
        /// which writes the FASTA at `exportURL`, and returns the sequences it holds. `cancellation` stops the
        /// export's process tree.
        typealias Preparer = @Sendable (
            _ arguments: [String], _ exportURL: URL, _ cancellation: LungfishCLIRunner.CancellationHandle
        ) async throws -> [(id: String, sequence: String)]

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
    /// ``launchTwelveSUnresolvedBlastSubmit(bundleURL:exportURL:arguments:controller:drawer:runner:prepare:)``
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
