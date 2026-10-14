// AppDelegate+ManagedMapping.swift - The Map Reads route, moved out of AppDelegate+ToolsMenu.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import os
import LungfishKit

extension AppDelegate {
    /// Precomputes the on-disk output layout for a mapping fan-out batch
    /// (BG3, batch-results-grouping spec §2/§3).
    ///
    /// Returns `nil` when `requests.count <= 1` -- the caller keeps the
    /// existing single-run behavior unchanged (each child creates its own
    /// flat `Analyses/<tool>-<timestamp>/` directory, exactly as before this
    /// change).
    ///
    /// For `requests.count > 1`, creates ONE
    /// `Analyses/<tool>-batch-<timestamp>/` directory up front, then walks
    /// `requests` **in their given order** -- never reordered, never
    /// computed inside a concurrently-running child -- creating one
    /// `batchSampleDirectory(named:in:)` per request via the bundle display
    /// name already used for that request's operation title/@RG SM tag
    /// (`request.sampleName`). This satisfies the spec §3 ordering
    /// invariant: sample directory names are fully determined before any
    /// child dispatch begins.
    ///
    /// Returns `nil` (rather than throwing) if directory creation fails, so
    /// callers can fall back to the pre-BG3 per-child behavior -- matching
    /// the existing `try?`-based failure tolerance of
    /// `createAnalysisDirectory` at the single-run call site.
    static func precomputedMappingBatchOutputDirectories(
        requests: [MappingRunRequest],
        in projectURL: URL,
        date: Date = Date()
    ) -> [URL]? {
        guard requests.count > 1,
              let tool = requests.first?.tool.rawValue,
              let batchDirectory = try? AnalysesFolder.createAnalysisDirectory(
                  tool: tool, in: projectURL, isBatch: true, date: date
              )
        else { return nil }

        var sampleDirectories: [URL] = []
        sampleDirectories.reserveCapacity(requests.count)
        for request in requests {
            guard let sampleDirectory = try? AnalysesFolder.batchSampleDirectory(
                named: request.sampleName, in: batchDirectory
            ) else { return nil }
            sampleDirectories.append(sampleDirectory)
        }
        return sampleDirectories
    }

    /// Runs a planned mapping request for every bundle in `plan`,
    /// SEQUENTIALLY (as the classifier batches ran) rather
    /// than N concurrent `Task.detached` mappers -- an unbounded fan-out
    /// would otherwise spawn N mappers each requesting up to
    /// `processorCount` threads plus N reference-index rebuilds
    /// simultaneously (F5 in the C2 fix-round-1 review). `.perBundle` plans
    /// start one independent `OperationCenter` operation per bundle in
    /// sequence, so each bundle's progress/success/failure is still
    /// individually tracked; `.combined` plans have exactly one pooled
    /// request, whose operation history gets `plan.warning` logged as a
    /// warning line before the run starts (MB-1: explicit pooled-naming +
    /// logged warning instead of silent @RG misattribution).
    ///
    /// BG3: when `plan.requests.count > 1`, all N children's results are
    /// grouped under one `Analyses/<tool>-batch-<timestamp>/` directory
    /// (`precomputedMappingBatchOutputDirectories`, computed once before the
    /// loop starts) instead of each child creating its own sibling
    /// `Analyses/<tool>-<timestamp>/` directory. If every child fails and
    /// leaves nothing behind, the now-empty batch directory is removed after
    /// the loop completes (spec §6).
    ///
    /// `routeSettings` reads the mapping key, the user's defaults unless a test passes its own suite.
    func runManagedMapping(
        plan: MappingRunPlan,
        routeContext explicitRouteContext: OperationRouteContext? = nil,
        routeSettings: ReadsLaunchRouteSettings = ReadsLaunchRouteSettings()
    ) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
        let route = routeSettings.route(for: .mapping)
        guard canWriteProjectOutputs(
            projectURL: routeContext?.projectURL,
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Read mapping"
        ) else { return }

        let requests = plan.requests
        guard !requests.isEmpty else { return }

        // Precomputed IN REQUEST ORDER, before any child dispatch (spec §3
        // ordering invariant) -- `nil` for a single-request plan, which
        // keeps the pre-BG3 per-child `createAnalysisDirectory` behavior
        // unchanged.
        let batchProjectURL = routeContext?.projectURL ?? requests.first?.projectURL
        let preassignedDirectories: [URL]? = batchProjectURL.flatMap {
            Self.precomputedMappingBatchOutputDirectories(requests: requests, in: $0)
        }
        let batchDirectory = preassignedDirectories?.first?.deletingLastPathComponent()

        // Declared before the Task literal (rather than `let task =
        // Task.detached { ... }`) so `registerCancel`'s closure, invoked
        // from inside the loop, can capture `taskHandle` by reference and
        // call `.cancel()` on whichever `Task` ends up assigned -- avoids
        // the "captures 'task' before it is declared" forward-reference
        // error a `let`-bound self-referential closure would hit here.
        // Zipped with `requests` (rather than indexed inside the loop) so
        // the loop body below can keep the exact `for request in requests`
        // shape `OperationRoutingTests` pins as evidence of the single
        // sequential `Task.detached` driver (F5) -- each element is either
        // this request's precomputed batch sample directory, or `nil` for a
        // single-request plan.
        let perRequestDirectories: [URL?] = preassignedDirectories ?? Array(repeating: nil, count: requests.count)
        // The children run one after another, so the batch root stays hidden
        // between them. The hold ends once the last child tracks the root,
        // so the root completes with that child rather than after the loop.
        let batchOutputHold = SequentialAnalysisBatchHold(directory: batchDirectory, childCount: requests.count)
        let taskHandle = MappingBatchTaskHandle()
        let task = Task.detached { [weak self] in
            var anySucceeded = false
            var preassignedIterator = perRequestDirectories.makeIterator()
            for request in requests {
                let preassignedDirectory = preassignedIterator.next() ?? nil
                if Task.isCancelled { break }
                guard let self else { break }
                // The mapping key's CLI route runs `lungfish-cli map` for the same request and
                // folder (decision C4). Its row's cancel also reaches the command at once.
                guard route == .legacy else {
                    let succeeded = await self.runSingleManagedMappingThroughCLI(
                        request: request,
                        warning: plan.warning,
                        routeContext: routeContext,
                        preassignedAnalysisDirectory: preassignedDirectory,
                        cancelBatch: { taskHandle.cancel() },
                        registerCancel: { @MainActor opID in
                            // The child now tracks its output, and so the batch root. The
                            // runner set the row's cancel already, so `opID` is not used here.
                            batchOutputHold.didLaunchChild()
                        }
                    )
                    anySucceeded = anySucceeded || succeeded
                    continue
                }
                let succeeded = await self.runSingleManagedMappingAwaitingCompletion(
                    request: request,
                    warning: plan.warning,
                    routeContext: routeContext,
                    preassignedAnalysisDirectory: preassignedDirectory,
                    registerCancel: { @MainActor opID in
                        // Cancelling any one bundle's row cancels the whole
                        // remaining sequential batch, since they share one
                        // outer Task; the currently in-flight bundle stops
                        // at its next cancellation checkpoint (resolveInputFiles
                        // / pipeline.run), and the loop's `Task.isCancelled`
                        // guard prevents any further bundle from starting.
                        OperationCenter.shared.setCancelCallback(for: opID) { taskHandle.cancel() }
                        // The child now tracks its output, and so the batch root.
                        batchOutputHold.didLaunchChild()
                    }
                )
                anySucceeded = anySucceeded || succeeded
            }

            // Empty-batch cleanup (spec §6): only after every child has
            // reached a terminal state (the sequential loop above has just
            // finished, whether by completion or cancellation) and only when
            // nothing succeeded -- a lone surviving sample directory (even
            // from a bundle whose own row later shows "failed" for a
            // post-output-write error) means the batch directory is not
            // empty and must stay.
            let batchSucceeded = anySucceeded
            await MainActor.run {
                batchOutputHold.finish(succeeded: batchSucceeded)
                if !batchSucceeded, let batchDirectory {
                    AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDirectory)
                }
            }
        }
        taskHandle.assign(task)
    }

    /// Runs one `MappingRunRequest` to completion (success or failure),
    /// awaiting the whole pipeline before returning, so the sequential loop
    /// in `runManagedMapping` never starts a second bundle's mapping while
    /// this one is still using the CPU/reference index.
    ///
    /// This method is a member of `AppDelegate` (`@MainActor`), so its
    /// declaration is `@MainActor`-isolated -- it does NOT run "exactly
    /// like" the old per-request `Task.detached` body, which executed on a
    /// background executor throughout. What actually keeps this off the
    /// main thread for the expensive parts is that `resolveManagedMappingInputs`,
    /// `ManagedMappingPipeline.run`, and `prepareMappingViewerBundleIfPossible`
    /// are themselves `async` calls whose bodies are not further
    /// `@MainActor`-isolated (`ManagedMappingPipeline` is a plain,
    /// non-actor `Sendable` class); `await`-ing them from a `@MainActor`
    /// caller still lets their own work run on a background executor, and
    /// control only returns to the main actor at each `await` resumption.
    /// This holds under the default Swift 6 model, where a non-actor `async`
    /// body runs on the caller-supplied executor; the package does not enable
    /// `NonisolatedNonsendingByDefault` (SE-0461), and the guarantee needs
    /// re-verification if it ever does. `registerCancel` is invoked with the
    /// freshly-started operation's ID so the caller can wire cancellation
    /// before any awaiting begins.
    ///
    /// `preassignedAnalysisDirectory`, when non-nil, is used verbatim as the
    /// request's output directory and the usual per-child
    /// `createAnalysisDirectory` call is skipped entirely (BG3: batch fan-out
    /// precomputes and passes one `batchSampleDirectory(named:in:)` per
    /// request BEFORE this method is ever invoked, so every child's
    /// directory already exists under a single shared batch root). `nil`
    /// preserves the original single-run behavior unchanged.
    ///
    /// Returns `true` if the mapping completed successfully, `false` if it
    /// failed -- callers use this to detect "every child in the batch
    /// failed" for the empty-batch cleanup in `runManagedMapping`.
    @discardableResult
    private func runSingleManagedMappingAwaitingCompletion(
        request initialRequest: MappingRunRequest,
        warning: String?,
        routeContext: OperationRouteContext?,
        preassignedAnalysisDirectory: URL? = nil,
        registerCancel: @MainActor (UUID) -> Void
    ) async -> Bool {
        var request = initialRequest
        // The Analyses/ folder this run owns: removed again if the run fails
        // or is cancelled, so a failed mapping never leaves a folder holding
        // only analysis-metadata.json that the sidebar lists as a result.
        var ownedAnalysisDirectory: URL?
        if let preassignedAnalysisDirectory {
            request = request.withOutputDirectory(preassignedAnalysisDirectory)
            ownedAnalysisDirectory = preassignedAnalysisDirectory
        } else {
            let projectURL = routeContext?.projectURL ?? request.projectURL
            if let projectURL,
               let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: request.tool.rawValue, in: projectURL) {
                request = request.withOutputDirectory(analysisDir)
                ownedAnalysisDirectory = analysisDir
            }
        }
        let discardOwnedAnalysisDirectory = {
            if let ownedAnalysisDirectory {
                AnalysesFolder.discardFailedAnalysisDirectory(ownedAnalysisDirectory)
            }
        }

        let began = Self.beginManagedMappingOperation(request: request, routeContext: routeContext) { opID in
            if let ownedAnalysisDirectory { OperationCenter.shared.trackAnalysisOutput(ownedAnalysisDirectory, for: opID) }
            registerCancel(opID)

            if let warning {
                OperationCenter.shared.log(id: opID, level: .warning, message: warning)
            }
        }
        guard let opID = began.startedID else {
            discardOwnedAnalysisDirectory()
            return false
        }
        // The first detail is logged too, as the bridge logs `map`'s start line (A46 M2).
        OperationCenter.shared.log(
            id: opID,
            level: .info,
            message: MappingRunProgress.startDetail(inputCount: request.inputFASTQURLs.count, reference: request.referenceFASTAURL)
        )

        do {
            if AppUITestConfiguration.current.isEnabled,
               AppUITestConfiguration.current.backendMode == .deterministic {
                let result = try AppUITestMappingBackend.writeResult(for: request)
                let outputDirectory = request.outputDirectory
                let capturedRequest = request
                guard OperationCenter.shared.complete(
                    id: opID,
                    detail: MappingRunProgress.completionDetail(mappedReads: result.mappedReads, totalReads: result.totalReads)
                ) else { return false }
                AppUITestConfiguration.current.appendEvent(
                    "mapping.operation.completed target=\(outputDirectory.lastPathComponent)"
                )
                routePostMappingDeterministicCompletion(
                    outputDirectory: outputDirectory,
                    request: capturedRequest
                )
                return true
            }

            // The steps and their words come from MappingRunProgress, which `map --format json`
            // reports too, so the row reads the same on the CLI route (A46 M1 review, ruling 1).
            let resolved = try await resolveManagedMappingInputs(for: request) { message in
                Self.showMappingStep(MappingRunProgress.resolving(message), opID: opID)
            }
            let resolvedRequest = resolved.request
            OperationCenter.shared.log(
                id: opID,
                level: .info,
                message: MappingRunProgress.readLayoutLine(for: resolvedRequest, reason: resolved.layoutResolution.reason)
            )
            let pipeline = ManagedMappingPipeline()
            let result = try await pipeline.run(
                request: resolvedRequest,
                inputLayoutReason: resolved.layoutResolution.reason,
                readSetPlan: resolved.readSetPlan
            ) { fraction, message in
                Self.showMappingStep(MappingRunProgress.mapping(fraction, message), opID: opID)
            }

            var finalResult = result
            if let preparedResult = try await self.prepareMappingViewerBundleIfPossible(
                result: result,
                request: resolvedRequest,
                opID: opID
            ) {
                finalResult = preparedResult
            }

            // capturedRequest carries the ORIGINAL (pre-resolve) input URLs
            // so findSourceBundle can still walk up to the enclosing bundle
            // even when resolveManagedMappingInputs materialized a virtual
            // bundle's reads into the run's .lungfish-map-inputs folder (which
            // has no enclosing .lungfishfastq bundle). But summaryParameters()
            // must come from resolvedRequest -- the request actually run
            // through the pipeline -- so the persisted manifest records the
            // resolved isPairedEnd and layout, not the dialog's request.
            let capturedRequest = request
            guard OperationCenter.shared.items.first(where: { $0.id == opID })?.state == .running else {
                discardOwnedAnalysisDirectory()
                OperationCenter.shared.acknowledgeCancellation(id: opID)
                return false
            }
            do {
                // The same analysis-history record `lungfish-cli map` writes.
                try MappingResultLayoutService.recordAnalysisManifest(
                    originalInputURLs: capturedRequest.inputFASTQURLs,
                    resolvedRequest: resolvedRequest,
                    result: finalResult,
                    projectURL: routeContext?.projectURL ?? capturedRequest.projectURL
                )
            } catch {
                appDelegateLogger.warning("Failed to record analysis manifest: \(error.localizedDescription, privacy: .public)")
            }

            guard OperationCenter.shared.complete(
                id: opID,
                detail: MappingRunProgress.completionDetail(mappedReads: finalResult.mappedReads, totalReads: finalResult.totalReads),
                bundleURLs: [finalResult.viewerBundleURL ?? finalResult.bamURL]
            ) else { return false }



            targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                .sidebarController.requestReloadFromFilesystem()
            return true
        } catch {
            // Interpolating `error` directly prints the enum case
            // name (e.g. "mapperNotInstalled(\"minimap2\")"), not the
            // user-facing text `ManagedMappingPipelineError` already
            // provides via `LocalizedError`.
            discardOwnedAnalysisDirectory()
            _ = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
            targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
                .sidebarController.requestReloadFromFilesystem()
            return false
        }
    }

    /// Turns the request the Map Reads dialog built (inputs are the bundles
    /// the user chose) into the request the pipeline runs, through the call
    /// `lungfish-cli map` makes: bundles resolved to their files, virtual
    /// bundles materialized into the run's `.lungfish-map-inputs`, pairing
    /// and layout from the read-set plan (READ-PAIRING.md), lineage carried
    /// (R3). The resolution runs off the main actor.
    func resolveManagedMappingInputs(
        for request: MappingRunRequest,
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: .shared),
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> MappingResolvedInputs {
        try await MappingInputResolver.resolve(request: request, materializer: materializer, progress: progress)
    }

    @MainActor
    private func routePostMappingDeterministicCompletion(
        outputDirectory: URL,
        request: MappingRunRequest
    ) {
        guard let split = mainWindowController?.mainSplitViewController else { return }
        if let bundleURL = MappingResultLayoutService.findSourceBundle(for: request.inputFASTQURLs) {
            let entry = AnalysisManifestEntry(
                tool: request.tool.rawValue,
                analysisDirectoryName: Self.analysisManifestDirectoryName(
                    for: outputDirectory,
                    projectURL: request.projectURL
                ),
                displayName: "\(request.tool.displayName) Mapping",
                parameters: request.summaryParameters(),
                summary: "Deterministic UI test mapping",
                status: .completed
            )
            try? AnalysisManifestStore.recordAnalysis(entry, bundleURL: bundleURL)
        }
        split.refreshSidebarAndDisplayMappingResult(at: outputDirectory)
    }

    /// Copies the reference bundle into the result directory with the BAM
    /// attached as a track and rewrites the sidecars, through the same
    /// `MappingResultLayoutService` that `lungfish-cli map` runs, so the
    /// window and the copied CLI command leave an identical layout. Returns
    /// `nil` when the reference is not inside a `.lungfishref` bundle.
    private func prepareMappingViewerBundleIfPossible(
        result: MappingResult,
        request: MappingRunRequest,
        opID: UUID
    ) async throws -> MappingResult? {
        // Logged as well as shown since 2.10, as the bridge logs `map`'s progress line (A46 M2).
        Self.showMappingStep(MappingRunProgress.preparingViewer, opID: opID)
        let publication = try await MappingResultLayoutService.publishViewerBundle(
            result: result,
            request: request,
            progress: { fraction, message in
                Self.showMappingStep(MappingRunProgress.publishingViewer(fraction, message), opID: opID)
            }
        )
        return publication?.result
    }

    /// Shows one step of a run on its row and logs its words at info, from any thread.
    nonisolated static func showMappingStep(_ step: MappingRunProgress.Step, opID: UUID) {
        DispatchQueue.main.async { MainActor.assumeIsolated {
            _ = OperationCenter.shared.update(id: opID, progress: step.fraction, detail: step.message)
            OperationCenter.shared.log(id: opID, level: .info, message: step.message)
        }}
    }

    // MARK: - The CLI route behind the mapping key

    /// The argv the mapping key's CLI route runs for `request`, which its row records: the command
    /// the in-process row records today, with `--format json` so the command prints its events
    /// and no text on standard output (decision C5).
    static func managedMappingCLIArguments(for request: MappingRunRequest) -> [String] {
        ["map"] + MappingCLIInvocationBuilder.arguments(for: request) + ["--format", "json"]
    }

    /// Runs one request through `lungfish-cli map` on `CLIReadsRunner` and returns whether its
    /// result stands (Phase 2.10, decisions C4 and C5). The row's title, first detail, folder,
    /// warning, UI-test backend and end of run are those of `runSingleManagedMappingAwaitingCompletion`.
    /// The command writes the BAM, the sidecars, the viewer bundle and the source bundle's analysis
    /// history, so the app only reads the result back to complete the row. The folder goes only when
    /// the run threw, with a failure or a cancel the command honoured, as on the in-process route. A
    /// run whose command finished keeps its folder whatever the row says (fix 8 of lane A46). A
    /// result that cannot be read fails the row and leaves the folder for review, and a cancel that
    /// came after the command finished ends the row cancelled with the result listed. The row's
    /// cancel cancels the batch through `cancelBatch` and reaches the command at once through the
    /// runner.
    func runSingleManagedMappingThroughCLI(
        request initialRequest: MappingRunRequest,
        warning: String?,
        routeContext: OperationRouteContext?,
        preassignedAnalysisDirectory: URL? = nil,
        runner: CLIReadsRunner = CLIReadsRunner(),
        cancelBatch: @escaping @Sendable () -> Void,
        registerCancel: @MainActor (UUID) -> Void
    ) async -> Bool {
        var request = initialRequest
        var ownedAnalysisDirectory: URL?
        if let preassignedAnalysisDirectory {
            request = request.withOutputDirectory(preassignedAnalysisDirectory)
            ownedAnalysisDirectory = preassignedAnalysisDirectory
        } else if let projectURL = routeContext?.projectURL ?? request.projectURL,
                  let analysisDir = try? AnalysesFolder.createAnalysisDirectory(tool: request.tool.rawValue, in: projectURL) {
            request = request.withOutputDirectory(analysisDir)
            ownedAnalysisDirectory = analysisDir
        }
        let discardOwnedAnalysisDirectory = {
            if let ownedAnalysisDirectory {
                AnalysesFolder.discardFailedAnalysisDirectory(ownedAnalysisDirectory)
            }
        }

        let arguments = Self.managedMappingCLIArguments(for: request)
        let began = Self.beginManagedMappingOperation(
            request: request,
            routeContext: routeContext,
            cliArguments: arguments
        ) { opID in
            if let ownedAnalysisDirectory { OperationCenter.shared.trackAnalysisOutput(ownedAnalysisDirectory, for: opID) }
            OperationCenter.shared.setCancelCallback(for: opID) {
                cancelBatch()
                runner.cancel()
            }
            registerCancel(opID)
            if let warning {
                OperationCenter.shared.log(id: opID, level: .warning, message: warning)
            }
        }
        guard let opID = began.startedID else {
            discardOwnedAnalysisDirectory()
            return false
        }

        // Only a run that threw, in the runner or in the UI-test backend, loses its folder.
        let uiTestResult: MappingResult?
        do {
            if AppUITestConfiguration.current.isEnabled,
               AppUITestConfiguration.current.backendMode == .deterministic {
                uiTestResult = try AppUITestMappingBackend.writeResult(for: request)
            } else {
                uiTestResult = nil
                // `map` is an events leaf (A46 M2), so the bridge shows its steps on the row and a
                // failure carries the failed line's words. A run that exited 0 with its `complete`
                // line returns even after a late cancel.
                _ = try await runner.runEvents(arguments: arguments, operationID: opID)
            }
        } catch is CancellationError {
            discardOwnedAnalysisDirectory()
            OperationCenter.shared.acknowledgeCancellation(id: opID)
            return false
        } catch {
            discardOwnedAnalysisDirectory()
            _ = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
            reloadSidebarAfterMapping(routeContext: routeContext)
            return false
        }

        if let result = uiTestResult {
            guard OperationCenter.shared.complete(
                id: opID,
                detail: MappingRunProgress.completionDetail(mappedReads: result.mappedReads, totalReads: result.totalReads)
            ) else { return false }
            AppUITestConfiguration.current.appendEvent(
                "mapping.operation.completed target=\(request.outputDirectory.lastPathComponent)"
            )
            routePostMappingDeterministicCompletion(outputDirectory: request.outputDirectory, request: request)
            return true
        }

        let outputDirectory = request.outputDirectory
        let result: MappingResult
        do {
            result = try await Task.detached { try MappingResult.load(from: outputDirectory) }.value
        } catch {
            // `map` finished, so its folder stays, unlisted, for review.
            _ = OperationCenter.shared.fail(id: opID, detail: error.localizedDescription)
            reloadSidebarAfterMapping(routeContext: routeContext)
            return false
        }
        if !OperationCenter.shared.complete(
            id: opID,
            detail: MappingRunProgress.completionDetail(mappedReads: result.mappedReads, totalReads: result.totalReads),
            bundleURLs: [result.viewerBundleURL ?? result.bamURL]
        ) {
            // The row took a cancel after `map` finished, so it ended cancelled. `map` wrote the
            // history entry before its `complete` line, so the result stays and is listed. A batch
            // root that a hold still keeps completes when the batch finishes.
            if let folder = ownedAnalysisDirectory.flatMap(AnalysesFolder.enclosingIncompleteAnalysisDirectory(for:)),
               !OperationCenter.shared.isTrackingAnalysisOutput(folder) {
                AnalysesFolder.markAnalysisComplete(folder)
            }
        }
        reloadSidebarAfterMapping(routeContext: routeContext)
        return true
    }

    private func reloadSidebarAfterMapping(routeContext: OperationRouteContext?) {
        targetMainWindowController(routeContext: routeContext)?.mainSplitViewController?
            .sidebarController.requestReloadFromFilesystem()
    }
}
