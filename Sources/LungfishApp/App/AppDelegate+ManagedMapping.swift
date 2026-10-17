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
    /// Each child runs `lungfish-cli map` (Phase 2.10, decision C4). It is the only route since Phase 2.11 (K3) took out
    /// the hidden mapping key and the in-process route it kept.
    func runManagedMapping(
        plan: MappingRunPlan,
        routeContext explicitRouteContext: OperationRouteContext? = nil
    ) {
        let routeContext = explicitRouteContext ?? currentOperationRouteContext()
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
                // `lungfish-cli map` runs for the same request and folder (decision C4). The row's
                // cancel also reaches the command at once.
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

    // MARK: - The CLI route

    /// The argv the CLI route runs for `request`, which its row records: `map` with the request's options and
    /// `--format json` so the command prints its events and no text on standard output (decision C5).
    static func managedMappingCLIArguments(for request: MappingRunRequest) -> [String] {
        ["map"] + MappingCLIInvocationBuilder.arguments(for: request) + ["--format", "json"]
    }

    /// Runs one request through `lungfish-cli map` on `CLIReadsRunner` and returns whether its
    /// result stands (Phase 2.10, decisions C4 and C5). The command writes the BAM, the sidecars, the viewer bundle and the source bundle's analysis
    /// history, so the app only reads the result back to complete the row. The folder goes only when
    /// the run threw, with a failure or a cancel the command honoured. A
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
