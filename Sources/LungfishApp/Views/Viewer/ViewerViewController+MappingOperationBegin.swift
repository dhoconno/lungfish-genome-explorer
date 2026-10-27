// ViewerViewController+MappingOperationBegin.swift - Operations panel registration for mapping viewport launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow
import LungfishCore
import LungfishIO
import SwiftUI

/// The begin helpers for the launches in the baselined
/// ViewerViewController+Mapping.swift (finding R4), and the viewer's
/// Generate Consensus action, which runs `lungfish-cli bam consensus` on the
/// L3 runner (Phase 2.10 lane A51, ruling A51-consensus). Each begin helper
/// registers a row through `OperationReporting` and calls `launch` only when
/// the row started, so a test can check the row and its command without
/// touching `OperationCenter.shared`. They live here, not beside their launch
/// sites, so the baselined file does not grow (scripts/ratchets/file-size.sh).
extension ViewerViewController {
    /// The argv after the binary that runs `invocation`, `bam consensus` with
    /// its events on (Phase 2.10 lane A51, ruling A51-consensus). The row
    /// records it and the L3 runner runs it.
    static func alignmentConsensusCLIArguments(_ invocation: AlignmentConsensusInvocation) -> [String] {
        Array(AlignmentConsensusPublicationService.replayArgv(invocation).dropFirst()) + ["--format", "json"]
    }

    /// The row's command for `invocation`, `lungfish-cli bam consensus ...`,
    /// built from the argv the runner runs.
    static func alignmentConsensusCLICommand(_ invocation: AlignmentConsensusInvocation) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "bam consensus",
            args: Array(alignmentConsensusCLIArguments(invocation).dropFirst(2))
        )
    }

    /// Registers the alignment consensus row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle, records the
    /// `lungfish-cli bam consensus` command of `invocation`, which names the
    /// chosen destination in `--output`, and logs the scope and the region.
    @discardableResult
    static func beginAlignmentConsensusGenerationOperation(
        invocation: AlignmentConsensusInvocation,
        routeContext: OperationRouteContext? = nil,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let region = invocation.region
        let result = reporter.begin(
            title: "Generate Alignment Consensus",
            detail: "Calling evidence-only consensus…",
            operationType: .export,
            cliCommand: alignmentConsensusCLICommand(invocation),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            reporter.log(
                id: operationID,
                level: .info,
                message: "Consensus scope \(region.scope.rawValue), region \(region.contig):\(region.start)-\(region.end), reference fill never"
            )
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Runs the row's `bam consensus` on the L3 runner and hands how it ended
    /// to `finish` on the main actor. When the leaf refuses a result that is N
    /// at every position, matched by its failed message, `confirmAllLowDepth`
    /// shows today's sheet. Its Cancel ends the row Cancelled with nothing
    /// written. Its Continue records the command with `--allow-all-low-depth`
    /// through `setCommand` and runs that. The leaf wrote every file before it
    /// exited, so the app writes nothing. The row's Cancel reaches the
    /// runner's `cancel()`. A cancelled run ends the row Cancelled with no
    /// alert and hands `finish` a `CancellationError` for its clean-up.
    ///
    /// `evidence` is the alignment evidence the viewer showed, with the
    /// digests it hashed when it showed them. Its snapshots are checked against
    /// the files before each run of the leaf, as the coordinator did before it
    /// fetched and before it published (review A51, B1), so a BAM replaced
    /// after it was shown ends the row failed with nothing written.
    @discardableResult
    static func runAlignmentConsensusThroughCLI(
        invocation: AlignmentConsensusInvocation,
        workingDirectory: URL?,
        operationID: UUID,
        evidence: AlignmentActionContext? = nil,
        runner: CLIAlignmentActionRunner = CLIAlignmentActionRunner(),
        confirmAllLowDepth: @escaping @MainActor () async -> Bool,
        finish: @escaping @MainActor (Result<CLIAlignmentActionRunner.Completion, any Error>) -> Void
    ) -> Task<Void, Never> {
        let refusal = CLISubprocessTransport.RunError.failedEvent(
            message: AlignmentConsensusPublicationService.allLowDepthRefusal,
            detail: nil
        )
        let task = Task(priority: .userInitiated) { @MainActor in
            do {
                do {
                    try await evidence?.validateCurrentSnapshots()
                    let arguments = alignmentConsensusCLIArguments(invocation)
                    finish(.success(try await runner.run(arguments: arguments, operationID: operationID, workingDirectory: workingDirectory)))
                } catch let error as CLISubprocessTransport.RunError where error == refusal {
                    guard await confirmAllLowDepth() else { throw CancellationError() }
                    let accepted = invocation.allowingAllLowDepth()
                    OperationCenter.shared.setCommand(id: operationID, command: alignmentConsensusCLICommand(accepted))
                    // The sheet held the row's Cancel. The second run takes it back.
                    OperationCenter.shared.setCancelCallback(for: operationID) { runner.cancel() }
                    // The sheet can stay open while the BAM is replaced, so the second run checks again.
                    try await evidence?.validateCurrentSnapshots()
                    let arguments = alignmentConsensusCLIArguments(accepted)
                    finish(.success(try await runner.run(arguments: arguments, operationID: operationID, workingDirectory: workingDirectory)))
                }
            } catch is CancellationError {
                OperationCenterCLIBridge.acknowledgeCancellation(operationID)
                finish(.failure(CancellationError()))
            } catch {
                finish(.failure(error))
            }
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            task.cancel()
            runner.cancel()
        }
        return task
    }

    /// Today's words of the all-N sheet for a run whose minimum depth is `minimumDepth`.
    static func alignmentConsensusAllLowDepthMessage(minimumDepth: Int) -> String {
        "Every position in the requested region is below the minimum depth of \(minimumDepth). The consensus will contain only N characters. You can continue without filling from the reference."
    }

    /// Today's summary, which the clipboard row logs and its Consensus Copied sheet shows.
    static func alignmentConsensusSummary(_ exportRequest: MappingConsensusExportRequest) -> String {
        let request = exportRequest.consensusRequest
        let filters = request.filters
        let groups = filters.readGroups.isEmpty ? "all" : filters.readGroups.sorted().joined(separator: ",")
        return [
            "Scope: \(exportRequest.region.scope.rawValue)",
            "Region: \(exportRequest.region.contig):\(exportRequest.region.start + 1)-\(exportRequest.region.end)",
            "Caller: \(request.mode.rawValue)",
            "Minimum depth/MAPQ/base quality: \(filters.minimumDepth)/\(filters.minimumMapQ)/\(filters.minimumBaseQuality)",
            "Excluded flags: \(filters.excludedFlags)",
            "Read groups: \(groups)",
            "Low-depth policy: N",
            "Reference-fill policy: never",
        ].joined(separator: "\n")
    }

    // MARK: - Reads of alignment evidence on the CLI (Phase 2.10 lane A51 M3)

    /// The argv after the binary that runs `invocation`, `extract reads` with its events on. The row
    /// records it and the L3 runner runs it.
    static func alignmentReadExtractionCLIArguments(_ invocation: AlignmentReadExtractionInvocation) -> [String] {
        invocation.arguments + ["--format", "json"]
    }

    /// The region run of `context`, as Extract Reads in Selected Region chose it.
    static func alignmentRegionExtractionInvocation(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String
    ) -> AlignmentReadExtractionInvocation {
        AlignmentReadExtractionInvocation(
            alignmentURL: context.alignmentURL,
            indexURL: context.indexURL,
            decodingReferenceURL: context.decodingReferenceURL,
            selection: .regions(
                ["\(region.contig):\(region.start + 1)-\(region.end)"],
                minimumMapQ: context.filters.minimumMapQ,
                excludedFlags: Int(context.filters.excludedFlags),
                readGroups: Array(context.filters.readGroups)
            ),
            readsName: outputBaseName,
            outputURL: destination.finalURL
        )
    }

    /// The selected-read run of `context` for `records`, whose names are in `namesFile`.
    static func selectedReadsExtractionInvocation(
        context: AlignmentActionContext,
        records: [AlignedRead],
        namesFile: URL,
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String
    ) -> AlignmentReadExtractionInvocation {
        var sources: [URL] = []
        if case .sourceFASTQs(let urls) = context.sourceReads { sources = urls }
        return AlignmentReadExtractionInvocation(
            alignmentURL: context.alignmentURL,
            indexURL: context.indexURL,
            decodingReferenceURL: context.decodingReferenceURL,
            selection: .readNames(.init(
                file: namesFile,
                sourceFASTQs: sources,
                keepReadPairs: true,
                recordsWithoutSequence: records.filter { $0.sequence.isEmpty || $0.sequence == "*" }.count
            )),
            readsName: outputBaseName,
            outputURL: destination.finalURL
        )
    }

    /// Registers the row of a read extraction on alignment evidence and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle, records the `lungfish-cli extract
    /// reads` command of `invocation`, which names the chosen bundle in `--output`, and logs the
    /// evidence it reads, as the coordinator's row did.
    @discardableResult
    static func beginAlignmentReadExtractionOperation(
        title: String,
        detail: String,
        invocation: AlignmentReadExtractionInvocation,
        evidence: AlignmentEvidenceIdentity,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let arguments = alignmentReadExtractionCLIArguments(invocation)
        let result = reporter.begin(
            title: title,
            detail: detail,
            operationType: .taxonomyExtraction,
            cliCommand: OperationCenter.buildCLICommand(subcommand: "extract reads", args: Array(arguments.dropFirst(2))),
            routeContext: routeContext
        )
        guard case .started(let operationID) = result else {
            return result // The panel already shows the refused row. Nothing was launched.
        }
        reporter.log(
            id: operationID,
            level: .info,
            message: "alignment evidence: workflow=\(evidence.workflow);resultID=\(evidence.resultID);sampleID=\(evidence.sampleID);evidenceID=\(evidence.evidenceID)"
        )
        launch(operationID)
        return result
    }

    /// Runs `arguments`, an `extract reads` argv, on the L3 runner for the row and hands how it ended
    /// to `finish` on the main actor. The row keeps its first detail, which names its action. The
    /// leaf wrote its reads and their record before it exited, so the app writes nothing. The row's
    /// Cancel reaches the runner's `cancel()`, and a cancelled run ends the row Cancelled with no
    /// sheet and no `finish`.
    ///
    /// `evidence` is the alignment evidence the viewer showed, with the digests it hashed when it
    /// showed them. Its snapshots are checked against the files before the leaf runs, as the
    /// coordinator did before it staged and before it published (review A51, B1), so a BAM
    /// replaced after it was shown fails the row with nothing published. The overlapping-reads row
    /// passes none, as at the base.
    @discardableResult
    static func runReadExtractionThroughCLI(
        arguments: [String],
        operationID: UUID,
        evidence: AlignmentActionContext? = nil,
        runner: CLIAlignmentActionRunner = CLIAlignmentActionRunner(),
        finish: @escaping @MainActor (Result<CLIAlignmentActionRunner.Completion, any Error>) -> Void
    ) -> Task<Void, Never> {
        let task = Task(priority: .userInitiated) { @MainActor in
            do {
                try await evidence?.validateCurrentSnapshots()
                finish(.success(try await runner.run(arguments: arguments, operationID: operationID, keepsFirstDetail: true)))
            } catch is CancellationError {
                OperationCenterCLIBridge.acknowledgeCancellation(operationID)
            } catch {
                finish(.failure(error))
            }
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            task.cancel()
            runner.cancel()
        }
        return task
    }

    /// Ends a region or selected-read row with the details the coordinator's row ended with.
    static func finishAlignmentReadExtraction(
        _ outcome: Result<CLIAlignmentActionRunner.Completion, any Error>,
        operationID: UUID
    ) {
        switch outcome {
        case .success(let completion):
            _ = OperationCenter.shared.complete(
                id: operationID,
                detail: "Alignment read extraction published",
                bundleURLs: completion.outputs.map { URL(fileURLWithPath: $0) }
            )
        case .failure(let error):
            _ = OperationCenter.shared.fail(
                id: operationID,
                detail: "Alignment read extraction failed",
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Extract Reads in Selected Region, published at the chosen `destination` by `extract reads`.
    func launchAlignmentRegionExtraction(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String,
        routeContext: OperationRouteContext
    ) {
        launchAlignmentReadExtraction(
            title: "Extract Reads in Selected Region",
            detail: "Preparing alignment read extraction…",
            invocation: Self.alignmentRegionExtractionInvocation(
                context: context, region: region, destination: destination, outputBaseName: outputBaseName
            ),
            context: context,
            routeContext: routeContext
        )
    }

    /// Extract Selected Reads. The sorted names go into a durable file beside the chosen bundle
    /// before the row begins, so the command the row records names no scratch file and replays.
    func launchSelectedReadsExtraction(
        context: AlignmentActionContext,
        records: [AlignedRead],
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String,
        routeContext: OperationRouteContext
    ) {
        let namesFile = AlignmentReadExtractionInvocation.readNamesFileURL(forBundle: destination.finalURL)
        do {
            try AlignmentReadExtractionInvocation.writeReadNames(records.map(\.name), to: namesFile)
        } catch {
            presentExtractionFailureAlert(title: "Extract Selected Reads Failed", message: error.localizedDescription)
            return
        }
        launchAlignmentReadExtraction(
            title: "Extract Selected Reads",
            detail: "Preparing selected-read extraction…",
            invocation: Self.selectedReadsExtractionInvocation(
                context: context, records: records, namesFile: namesFile,
                destination: destination, outputBaseName: outputBaseName
            ),
            context: context,
            routeContext: routeContext
        )
    }

    /// Begins the row for `invocation` and runs it, once the viewer's evidence in `context` still
    /// matches the files it was hashed from.
    private func launchAlignmentReadExtraction(
        title: String,
        detail: String,
        invocation: AlignmentReadExtractionInvocation,
        context: AlignmentActionContext,
        routeContext: OperationRouteContext
    ) {
        Self.beginAlignmentReadExtractionOperation(
            title: title, detail: detail, invocation: invocation, evidence: context.identity, routeContext: routeContext
        ) { operationID in
            activeSelectedReadsExtractionTask = Self.runReadExtractionThroughCLI(
                arguments: Self.alignmentReadExtractionCLIArguments(invocation),
                operationID: operationID,
                evidence: context
            ) { outcome in
                Self.finishAlignmentReadExtraction(outcome, operationID: operationID)
            }
        }
    }

    /// Registers the overlapping-reads row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle and records the
    /// `lungfish-cli extract reads --by-region` command the L3 runner runs
    /// (``overlappingReadsExtractionCLIArguments(config:)``).
    @discardableResult
    static func beginOverlappingReadsExtractionOperation(
        annotationName: String,
        config: BAMRegionExtractionConfig,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract Overlapping Reads",
            detail: "Extracting reads overlapping \(annotationName)…",
            operationType: .taxonomyExtraction,
            cliCommand: overlappingReadsExtractionCLICommand(config: config)
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The argv after the binary that the overlapping-reads row records and the L3 runner runs,
    /// `extract reads --by-region` for this configuration with its events on (Phase 2.10 lane
    /// A51, p48). The run writes `<outputBaseName>.fastq` in the output directory, so the command
    /// names that file in `-o`. The annotation action sets no map quality, flag or read group
    /// filter, and its duplicate exclusion is the command's default, so the command needs no
    /// option for them. It names no index because the CLI finds the BAM's companion index, the
    /// mapping's own. Each coordinate region, such as `chr1:11-25`, goes to samtools as given, so
    /// the row writes the reads that overlap the annotation's blocks.
    static func overlappingReadsExtractionCLIArguments(config: BAMRegionExtractionConfig) -> [String] {
        var arguments = ["extract", "reads", "--by-region", "--bam", config.bamURL.path]
        for region in config.regions {
            arguments += ["--region", region]
        }
        let outputName = "\(ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)).fastq"
        return arguments + ["-o", config.outputDirectory.appendingPathComponent(outputName).path, "--format", "json"]
    }

    /// The command the overlapping-reads row records, ``overlappingReadsExtractionCLIArguments(config:)``.
    static func overlappingReadsExtractionCLICommand(config: BAMRegionExtractionConfig) -> String {
        OperationCenter.buildCLICommand(subcommand: "extract reads", args: Array(overlappingReadsExtractionCLIArguments(config: config).dropFirst(2)))
    }

    /// Shared evidence-only consensus action for mapping, direct reference,
    /// and detached classifier full viewers. The destination is chosen first,
    /// then the row begins with the `bam consensus` command the runner runs,
    /// so a cancel of the sheet or of the save panel leaves no row and starts
    /// no process (ruling A51-consensus).
    func presentAlignmentConsensusGeneration() {
        if let priorOperationID = activeConsensusGenerationOperationID {
            OperationCenter.shared.cancel(id: priorOperationID)
            clearConsensusWorkflow(operationID: priorOperationID)
        }
        guard let context = alignmentActionContext else {
            presentExtractionFailureAlert(
                title: "Generate Consensus Failed",
                message: AlignmentScientificActionError.contextUnavailable.localizedDescription
            )
            return
        }
        let exportRequest: MappingConsensusExportRequest
        do {
            let region = try alignmentConsensusScope.resolve(
                in: context,
                selection: explicitAlignmentSelection
            )
            exportRequest = try MappingConsensusExportRequestBuilder.build(
                sampleName: context.identity.sampleID,
                context: context,
                region: region,
                consensusMode: viewerView.consensusModeSetting,
                useAmbiguity: viewerView.consensusUseAmbiguitySetting
            )
        } catch {
            presentExtractionFailureAlert(title: "Generate Consensus Failed", message: error.localizedDescription)
            return
        }
        guard let window = view.window, window.attachedSheet == nil else {
            presentExtractionFailureAlert(
                title: "Generate Consensus Failed",
                message: "An application window is required to choose a consensus destination."
            )
            return
        }
        let model = FASTASequenceExtractionDialogModel(
            selectionCount: 1,
            suggestedName: exportRequest.suggestedName,
            bundleOpensSavePanel: consensusProjectURL(for: context) == nil
        )
        let sheet = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let dialog = FASTASequenceExtractionDialog(
            model: model,
            onCancel: { [weak window, weak sheet] in
                if let window, let sheet, window.attachedSheet === sheet { window.endSheet(sheet) }
            },
            onPrimary: { [weak self, weak window, weak sheet] in
                guard let self, let window, let sheet else { return }
                if window.attachedSheet === sheet { window.endSheet(sheet) }
                let requested = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
                chooseAlignmentConsensusOutput(
                    model.destination,
                    name: requested.isEmpty ? exportRequest.suggestedName : requested,
                    context: context,
                    exportRequest: exportRequest,
                    window: window
                )
            }
        )
        sheet.contentViewController = NSHostingController(rootView: dialog)
        window.beginSheet(sheet)
    }

    /// Resolves where the run writes and launches it. Clipboard and share run
    /// in a registered temp folder with `--output` a file name relative to it,
    /// the contract's one relative path. File takes the save panel's choice, as
    /// does a bundle with no project, and its cancel launches nothing. A bundle
    /// in a project goes into it with no panel (ViewerViewController+ConsensusDestination.swift).
    private func chooseAlignmentConsensusOutput(
        _ destination: DialogDestination,
        name: String,
        context: AlignmentActionContext,
        exportRequest: MappingConsensusExportRequest,
        window: NSWindow
    ) {
        let fileName = ExtractionBundleNaming.sanitizeFilename(name)
        switch destination {
        case .clipboard, .share:
            let directory: URL
            do {
                directory = try TempFileManager.shared.createRegisteredTempDirectory(prefix: "lungfish-consensus-\(destination.rawValue)-")
            } catch {
                presentExtractionFailureAlert(title: "Generate Consensus Failed", message: error.localizedDescription)
                return
            }
            launchAlignmentConsensus(
                destination, output: "\(fileName).fasta", workingDirectory: directory,
                context: context, exportRequest: exportRequest, window: window
            )
        case .bundle, .file:
            Task { @MainActor [weak self] in
                guard let self,
                      let output = await resolveConsensusFileOutput(destination, fileName: fileName, context: context, window: window) else {
                    return
                }
                launchAlignmentConsensus(
                    destination, output: output, workingDirectory: nil,
                    context: context, exportRequest: exportRequest, window: window
                )
            }
        }
    }

    /// Begins the row with the `bam consensus` command that writes `output`
    /// and runs it on the L3 runner.
    private func launchAlignmentConsensus(
        _ destination: DialogDestination,
        output: String,
        workingDirectory: URL?,
        context: AlignmentActionContext,
        exportRequest: MappingConsensusExportRequest,
        window: NSWindow
    ) {
        let invocation = AlignmentConsensusInvocation(
            context: context,
            region: exportRequest.region,
            consensusRequest: exportRequest.consensusRequest,
            recordName: exportRequest.recordName,
            output: output
        )
        let message = Self.alignmentConsensusAllLowDepthMessage(minimumDepth: exportRequest.minDepth)
        let summary = Self.alignmentConsensusSummary(exportRequest)
        let started = Self.beginAlignmentConsensusGenerationOperation(invocation: invocation, routeContext: consensusRouteContext(for: context)) { operationID in
            activeConsensusGenerationOperationID = operationID
            activeConsensusGenerationTask = Self.runAlignmentConsensusThroughCLI(
                invocation: invocation,
                workingDirectory: workingDirectory,
                operationID: operationID,
                evidence: context,
                confirmAllLowDepth: { [weak self, weak window] in
                    guard let self, let window else { return false }
                    return await confirmAllLowDepthConsensus(message: message, on: window, operationID: operationID)
                },
                finish: { [weak self, weak window] outcome in
                    // The row ends whether or not the viewer is still open.
                    Self.finishAlignmentConsensus(
                        outcome, viewer: self, destination: destination, summary: summary,
                        workingDirectory: workingDirectory, operationID: operationID, window: window
                    )
                }
            )
        }
        if case .refused = started, let workingDirectory {
            Self.removeConsensusTempDirectory(workingDirectory)
        }
    }

    /// Ends the row as today's route did for each destination, also once
    /// `viewer` has closed, so no row is left running. The leaf wrote the FASTA
    /// or the bundle with its record before it exited, so those rows complete
    /// without the viewer. Clipboard reads the FASTA back and share offers it
    /// with its record, both from the temp folder, which goes once they are
    /// done. Sheets need the viewer, and share without it ends as today's
    /// route ended a closed viewer's row.
    private static func finishAlignmentConsensus(
        _ outcome: Result<CLIAlignmentActionRunner.Completion, any Error>,
        viewer: ViewerViewController?,
        destination: DialogDestination,
        summary: String,
        workingDirectory: URL?,
        operationID: UUID,
        window: NSWindow?
    ) {
        let removeTemp = { if let workingDirectory { removeConsensusTempDirectory(workingDirectory) } }
        let completion: CLIAlignmentActionRunner.Completion
        switch outcome {
        case .failure(let error) where error is CancellationError:
            removeTemp()
            viewer?.clearConsensusWorkflow(operationID: operationID)
            return
        case .failure(let error):
            removeTemp()
            let accepted = OperationCenter.shared.fail(
                id: operationID,
                detail: "Alignment consensus failed",
                errorMessage: error.localizedDescription
            )
            viewer?.clearConsensusWorkflow(operationID: operationID)
            guard accepted else { return }
            viewer?.presentExtractionFailureAlert(title: "Generate Consensus Failed", message: error.localizedDescription)
            return
        case .success(let value):
            completion = value
        }
        let outputs = completion.outputs.map { URL(fileURLWithPath: $0) }
        switch destination {
        case .file:
            _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus FASTA saved", outputURLs: outputs)
            viewer?.clearConsensusWorkflow(operationID: operationID)
        case .bundle:
            _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus reference bundle created", bundleURLs: outputs)
            viewer?.clearConsensusWorkflow(operationID: operationID)
        case .clipboard:
            let task = Task { @MainActor [weak viewer] in
                defer { removeTemp() }
                do {
                    guard let fastaURL = outputs.first else { throw CLISubprocessTransport.RunError.missingCompletion }
                    let fasta = try await Task.detached { try String(contentsOf: fastaURL, encoding: .utf8) }.value
                    DefaultPasteboard().setString(fasta)
                    OperationCenter.shared.log(id: operationID, level: .info, message: summary)
                    _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus copied to clipboard")
                    viewer?.clearConsensusWorkflow(operationID: operationID)
                    guard let window else { return }
                    let alert = NSAlert()
                    alert.messageText = "Consensus Copied"
                    alert.informativeText = summary
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: window, completionHandler: nil)
                } catch {
                    let accepted = OperationCenter.shared.fail(id: operationID, detail: "Alignment consensus failed", errorMessage: error.localizedDescription)
                    viewer?.clearConsensusWorkflow(operationID: operationID)
                    guard accepted else { return }
                    viewer?.presentExtractionFailureAlert(title: "Generate Consensus Failed", message: error.localizedDescription)
                }
            }
            viewer?.activeConsensusGenerationTask = task
        case .share:
            guard let viewer else {
                removeTemp()
                OperationCenter.shared.acknowledgeCancellation(id: operationID, detail: "Originating viewer closed")
                return
            }
            let sessionID = UUID()
            let session = AlignmentConsensusShareSession(
                cleanup: removeTemp,
                finish: { [weak viewer] outcome in
                    viewer?.activeConsensusShareSessions[sessionID] = nil
                    switch outcome {
                    case .shared:
                        _ = OperationCenter.shared.complete(id: operationID, detail: "Consensus shared")
                    case .cancelled:
                        OperationCenter.shared.acknowledgeCancellation(id: operationID)
                    case .failed(let message):
                        _ = OperationCenter.shared.fail(id: operationID, detail: "Consensus share failed", errorMessage: message)
                    }
                    viewer?.clearConsensusWorkflow(operationID: operationID)
                }
            )
            viewer.activeConsensusShareSessions[sessionID] = session
            OperationCenter.shared.setCancelCallback(for: operationID) {
                DispatchQueue.main.async { session.cancel() }
            }
            session.present(items: outputs, relativeTo: viewer.view, preferredEdge: .minY)
        }
    }

    /// Removes a clipboard or share run's temp folder and its registration.
    static func removeConsensusTempDirectory(_ directory: URL) {
        TempFileManager.shared.unregisterSessionTempDirectory(directory)
        try? FileManager.default.removeItem(at: directory)
    }

    private func confirmAllLowDepthConsensus(
        message: String,
        on window: NSWindow,
        operationID: UUID
    ) async -> Bool {
        if let alignmentConsensusAllLowDepthConfirmation {
            return await alignmentConsensusAllLowDepthConfirmation(message, window)
        }
        guard window.attachedSheet == nil else { return false }
        return await presentAlignmentConsensusAllLowDepthConfirmation(
            message: message,
            on: window,
            operationID: operationID
        )
    }

    func presentAlignmentConsensusAllLowDepthConfirmation(
        message: String,
        on window: NSWindow,
        operationID: UUID
    ) async -> Bool {
        guard OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else { return false }
        return await withCheckedContinuation { continuation in
            let gate = AlignmentConsensusConfirmationGate(continuation)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Consensus Contains Only N"
            alert.informativeText = message
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            OperationCenter.shared.setCancelCallback(for: operationID) { [weak window, weak alertWindow = alert.window] in
                DispatchQueue.main.async {
                    if let window, let alertWindow, window.attachedSheet === alertWindow {
                        window.endSheet(alertWindow, returnCode: .cancel)
                    }
                    gate.resolve(false)
                }
            }
            alert.beginSheetModal(for: window) { response in
                gate.resolve(response == .alertFirstButtonReturn)
            }
        }
    }

    func finishConsensusWorkflow(operationID: UUID, cancellation: Bool) {
        if cancellation { OperationCenter.shared.acknowledgeCancellation(id: operationID) }
        clearConsensusWorkflow(operationID: operationID)
    }

    private func clearConsensusWorkflow(operationID: UUID) {
        guard activeConsensusGenerationOperationID == operationID else { return }
        activeConsensusGenerationTask = nil
        activeConsensusGenerationOperationID = nil
    }
}

@MainActor
private final class AlignmentConsensusConfirmationGate {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: accepted)
    }
}

@MainActor
final class AlignmentConsensusShareSession: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    enum Outcome: Equatable { case shared, cancelled, failed(String) }

    private let cleanup: () -> Void
    private let finish: (Outcome) -> Void
    private var picker: NSSharingServicePicker?
    private var didFinish = false

    init(cleanup: @escaping () -> Void, finish: @escaping (Outcome) -> Void) {
        self.cleanup = cleanup
        self.finish = finish
    }

    func present(items: [Any], relativeTo view: NSView, preferredEdge: NSRectEdge) {
        let picker = NSSharingServicePicker(items: items)
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: preferredEdge)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard let service else {
            complete(.cancelled)
            return
        }
        service.delegate = self
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        complete(.shared)
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        complete(.failed(error.localizedDescription))
    }

    func cancel() {
        complete(.cancelled)
    }

    private func complete(_ outcome: Outcome) {
        guard !didFinish else { return }
        didFinish = true
        picker = nil
        cleanup()
        finish(outcome)
    }
}
