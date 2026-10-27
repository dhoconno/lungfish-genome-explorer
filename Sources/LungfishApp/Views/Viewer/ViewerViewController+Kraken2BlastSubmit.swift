// ViewerViewController+Kraken2BlastSubmit.swift - The Kraken2 taxon's BLAST Verify on `lungfish-cli blast submit`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension ViewerViewController {
    /// The BLAST Verify of a Kraken2 taxon on `blast submit` (2.12 lane 12.10, A65-P50), for the tree display and
    /// the database-backed one. With no project it shows the `No Project Open` refusal and begins nothing (DEC Q-U8).
    /// Otherwise the row begins first and the read lookup runs in its task, so Cancel stops the lookup (12.08
    /// review Fix 4). The drawer shows the search on the taxonomy view's run, and a failure also shows the alert the
    /// row showed before.
    func beginKraken2BlastSubmit(
        controller: TaxonomyViewController?,
        node: TaxonNode,
        readCount: Int,
        classResult: ClassificationResult,
        sourceInputs: [URL],
        resultDirectory: URL,
        sample: String? = nil
    ) {
        guard let projectURL = blastSubmitProjectURL() ?? ProjectTempDirectory.findProjectRoot(resultDirectory) else {
            Self.refuseBlastWithoutProject(window: view.window)
            return
        }
        let taxonName = node.name
        let taxId = node.taxId
        let tree = classResult.tree
        let classificationOutput = classResult.outputURL
        let readFileIdentities = classResult.config.readFileIdentities
        Self.launchKraken2BlastSubmit(
            taxonName: taxonName, projectURL: projectURL, resultDirectory: resultDirectory, sample: sample,
            lookup: {
                try await Self.kraken2BlastLookup(
                    taxonName: taxonName, taxId: taxId, tree: tree, classificationOutput: classificationOutput,
                    sourceInputs: sourceInputs, readCount: readCount
                )
            },
            readsChangedNote: {
                await Self.kraken2BlastChangedFilesNote(identities: readFileIdentities, sourceInputs: sourceInputs)
            }
        ) { [weak controller] operationID in
            let runID = controller?.beginBlastVerification(for: node)
            // The drawer's own Cancel button reads this to cancel the run.
            controller?.currentBlastOperationID = operationID
            return BlastSubmitDrawer(
                loading: { [weak controller] in controller?.showBlastLoading(phase: $0, requestId: nil, runID: runID) },
                results: { [weak controller] in controller?.showBlastResults($0, recordURL: $1, runID: runID) },
                failure: { [weak controller] text in
                    controller?.showBlastFailure(message: text, runID: runID)
                    showBlastVerificationErrorAlert(text)
                }
            )
        }
    }

    /// The row of a Kraken2 search on `blast submit`. It begins with no command and runs `lookup` in its task, so a
    /// cancel during the lookup ends the row Cancelled with no search, no stage and no alert. The row then takes the
    /// plan's command through `setCommand`, the argv the leaf runs, and ``launchBlastSubmit(_:operationID:runner:drawer:completeDetail:)``
    /// runs it on `runner` with the drawer `makeDrawer` gives for the row, replacing the row's cancel callback with
    /// the runner's before anything awaits. `readsChangedNote` runs once the lookup has built the request, so every
    /// drawn read passed the read check, and gives the words that the read files changed after the result was made,
    /// which the row logs before the search goes on (BIO-READ-IDENTITY B1). Returns the row's task, or nil when the
    /// panel refused the row.
    @discardableResult
    static func launchKraken2BlastSubmit(
        taxonName: String,
        projectURL: URL,
        resultDirectory: URL,
        sample: String? = nil,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner(),
        lookup: @escaping @Sendable () async throws -> BlastVerificationRequest,
        readsChangedNote: (@Sendable () async -> String?)? = nil,
        makeDrawer: (UUID) -> BlastSubmitDrawer
    ) -> Task<Void, Never>? {
        var launched: Task<Void, Never>?
        beginKraken2BlastVerificationOperation(taxonName: taxonName, cliCommand: nil) { operationID in
            let drawer = makeDrawer(operationID)
            drawer.loading(.submitting)
            let task = Task { @MainActor in
                do {
                    let request = try await lookup()
                    let filesChanged = await readsChangedNote?()
                    try Task.checkCancellation()
                    // A Cancel moves the row to cancelling at once but stops this task a moment later, so the
                    // row is asked as well as the task (12.08 fix recipe, step 5).
                    guard OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else {
                        throw CancellationError()
                    }
                    if let filesChanged {
                        _ = OperationCenter.shared.updateWithLog(id: operationID, progress: 0.05, detail: filesChanged)
                    }
                    let plan = try kraken2BlastSubmitPlan(
                        request: request, projectURL: projectURL, resultDirectory: resultDirectory, sample: sample
                    )
                    OperationCenter.shared.setCommand(id: operationID, command: plan.cliCommand)
                    _ = OperationCenter.shared.updateWithLog(
                        id: operationID, progress: 0.1, detail: "Submitting \(request.sequences.count) reads to NCBI BLAST\u{2026}"
                    )
                    await launchBlastSubmit(plan, operationID: operationID, runner: runner, drawer: drawer) {
                        blastVerificationCompletionDetail($0)
                    }.value
                } catch is CancellationError {
                    OperationCenter.shared.acknowledgeCancellation(id: operationID)
                } catch {
                    let text = error.localizedDescription
                    guard OperationCenter.shared.fail(id: operationID, detail: text, errorMessage: text) else { return }
                    drawer.failure(text)
                }
            }
            OperationCenter.shared.setCancelCallback(for: operationID) { task.cancel() }
            launched = task
        }
        return launched
    }

    /// The Kraken2 taxon's search on `blast submit`. It sends the reads of `request`, which
    /// `kraken2BlastVerificationRequest` draws from every source file of the result with seed 0, and judges hits on
    /// that request's clade and genus relatives. The record names the Kraken2 result folder (`--source-result`), the
    /// sample when the display has one, the taxon and the count and seed of the draw. The search's folder sits under
    /// the result's `blast-verifications/`, where `blast verify --result-dir` and the in-process row kept theirs and
    /// where a reopened result finds it (``TaxonomyViewController/newestSavedBlastVerification(forTaxId:in:)``).
    /// It searches the request's database, `nt` as the in-process row and the BLAST popover have it, so the
    /// command carries `--database nt` and the record's argv names it (BIO 3, BIO 4).
    nonisolated static func kraken2BlastSubmitPlan(
        request: BlastVerificationRequest,
        projectURL: URL?,
        resultDirectory: URL,
        sample: String? = nil,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        let plan = try BlastSubmitPlan.make(
            request: request, projectURL: projectURL, sourceResultURL: resultDirectory, sample: sample,
            subsampleCount: request.sequences.count, subsampleSeed: 0, date: date
        )
        var submit = plan.request
        submit.database = request.database
        return BlastSubmitPlan(request: submit, queryData: plan.queryData)
    }

    /// The read lookup of a Kraken2 taxon off the main actor.
    @concurrent nonisolated static func kraken2BlastLookup(
        taxonName: String,
        taxId: Int,
        tree: TaxonTree,
        classificationOutput: URL,
        sourceInputs: [URL],
        readCount: Int
    ) async throws -> BlastVerificationRequest {
        try await kraken2BlastVerificationRequest(
            taxonName: taxonName, taxId: taxId, tree: tree, classificationOutput: classificationOutput,
            sourceInputs: sourceInputs, readCount: readCount
        )
    }

    /// The words that the read files of `sourceInputs` changed after the result was made, when a size in `identities`
    /// is not the file's size now, else nil (BIO-READ-IDENTITY B1). It is one `stat` per file, off the main actor.
    @concurrent nonisolated static func kraken2BlastChangedFilesNote(identities: [ReadFileIdentity]?, sourceInputs: [URL]) async -> String? {
        guard KrakenResultReadSources.readFilesChanged(identities: identities) else { return nil }
        return KrakenResultReadSources.changedReadsNote(place: KrakenResultReadSources.place(of: sourceInputs))
    }
}
