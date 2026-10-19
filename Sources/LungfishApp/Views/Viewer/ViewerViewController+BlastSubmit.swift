// ViewerViewController+BlastSubmit.swift - The viewers' BLAST actions on `lungfish-cli blast submit`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What a BLAST drawer shows while its search runs and once it ends.
struct BlastSubmitDrawer: Sendable {
    let loading: @MainActor @Sendable (BlastJobPhase) -> Void
    let results: @MainActor @Sendable (BlastVerificationResult, URL?) -> Void
    let failure: @MainActor @Sendable (String) -> Void
}

extension ViewerViewController {
    /// A FASTA BLAST search as the viewer runs it. The result comes with the file of its `blast submit` record, which
    /// the drawer keeps for its table export (ARCH ruling T5 of lane 12.33). A test's runner gives none.
    typealias FASTABlastSearch = @MainActor (
        _ request: BlastVerificationRequest,
        _ progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> (result: BlastVerificationResult, recordURL: URL?)

    /// The project of this viewer's window, whose `.tmp` takes a BLAST query.
    func blastSubmitProjectURL() -> URL? {
        let windowController = view.window?.windowController as? MainWindowController
        let split = windowController?.mainSplitViewController ?? (parent as? MainSplitViewController)
        let session = windowController?.projectSession ?? split?.projectSession
        return session?.projectURL ?? split?.sidebarController?.currentProjectURL
    }

    /// Shows the `No Project Open` refusal of a BLAST action through ``AppDelegate/NoProjectPresenterSeam``,
    /// a sheet on `window` or app-modal with none, with one OK button (2.12 lane 12.08, DEC Q-U8). The
    /// action begins no row and writes nothing.
    static func refuseBlastWithoutProject(window: NSWindow?) {
        AppDelegate.NoProjectPresenterSeam.presenter.present(
            title: BlastSubmitPlanError.noProjectTitle,
            message: BlastSubmitPlanError.noProject.localizedDescription,
            on: window
        )
    }

    /// The plan `makePlan` gives a BLAST action, or nil once the action has said why it starts nothing.
    /// With no project the plan refuses before it writes a byte and this shows the `No Project Open`
    /// refusal on `window`. Any other error goes to `failure`, the drawer. Every site on `blast submit`
    /// plans through here and begins its row only with a plan.
    static func blastSubmitPlan<Plan>(
        window: NSWindow?,
        failure: (String) -> Void,
        _ makePlan: () throws -> Plan
    ) -> Plan? {
        do {
            return try makePlan()
        } catch BlastSubmitPlanError.noProject {
            refuseBlastWithoutProject(window: window)
        } catch {
            failure(error.localizedDescription)
        }
        return nil
    }

    /// The FASTA selection's search on `blast submit`, or nil while a test's `fastaBlastVerificationRunner`
    /// stands in for it.
    func fastaBlastSubmitPlan(sourceLabel: String, sequences: [(id: String, sequence: String)]) throws -> BlastSubmitPlan? {
        guard fastaBlastVerificationRunner == nil else { return nil }
        let source = fastaExportSourceURLs().first
        return try Self.fastaSelectionBlastSubmitPlan(
            sourceLabel: sourceLabel, sequences: sequences, sourceURL: source,
            projectURL: blastSubmitProjectURL() ?? source.flatMap(ProjectTempDirectory.findProjectRoot)
        )
    }

    /// The search of selected FASTA sequences (2.11 A65 M2). The record names the file or bundle they
    /// came from, and the result goes under the project's `blast-verifications/`, never into a bundle.
    nonisolated static func fastaSelectionBlastSubmitPlan(
        sourceLabel: String,
        sequences: [(id: String, sequence: String)],
        sourceURL: URL?,
        projectURL: URL?,
        date: Date = Date()
    ) throws -> BlastSubmitPlan {
        try BlastSubmitPlan.make(
            sequences: sequences, label: sourceLabel, projectURL: projectURL, sourceResultURL: sourceURL,
            outputParentURL: projectURL, date: date
        )
    }

    /// The search of the FASTA selection's row: a test's `override`, else `plan` on `blast submit` with
    /// its events on the row through `OperationCenterCLIBridge` and its progress on the drawer. Cancelling
    /// the row's task stops the leaf. `fastaBlastSubmitPlan` gives no plan only while an override stands in.
    static func fastaBlastRunner(
        plan: BlastSubmitPlan?,
        operationID: UUID,
        override: FASTABlastVerificationRunner?
    ) -> FASTABlastSearch {
        if let override {
            return { request, progress in
                let result = try await override(request, progress)
                return (result, nil)
            }
        }
        guard let plan else {
            preconditionFailure("A FASTA BLAST search needs a plan or a test's runner")
        }
        let bridge = OperationCenterCLIBridge.onEvent(operationID: operationID)
        return { _, progress in
            let completed = try await plan.run(runner: CLIBlastSubmitRunner()) { event in
                bridge(event)
                if case let .progress(fraction, message) = event { progress(fraction, message) }
            }
            return (completed.result, completed.recordURL)
        }
    }

    /// Runs `plan` for the row `operationID` on `runner` (2.11 A65 M2, decision C5 of 2.10). The leaf's
    /// events reach the row through `OperationCenterCLIBridge`, each progress message sets the drawer's
    /// phase, and Cancel stops the leaf's whole process tree through the runner. The row completes with
    /// `completeDetail` of the verdicts the record holds.
    @discardableResult
    static func launchBlastSubmit(
        _ plan: BlastSubmitPlan,
        operationID: UUID,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner(),
        drawer: BlastSubmitDrawer,
        completeDetail: @escaping @Sendable (BlastVerificationResult) -> String
    ) -> Task<Void, Never> {
        drawer.loading(.submitting)
        let onEvent = OperationCenterCLIBridge.onEvent(operationID: operationID) { message in
            drawer.loading(BlastSubmitPlan.phase(forProgressMessage: message))
        }
        let task = Task { @MainActor in
            do {
                let completed = try await plan.run(runner: runner, onEvent: onEvent)
                guard OperationCenter.shared.complete(id: operationID, detail: completeDetail(completed.result)) else { return }
                drawer.results(completed.result, completed.recordURL)
            } catch is CancellationError {
                OperationCenter.shared.acknowledgeCancellation(id: operationID)
            } catch {
                let errorText = error.localizedDescription
                guard OperationCenter.shared.fail(id: operationID, detail: errorText, errorMessage: errorText) else { return }
                drawer.failure(errorText)
            }
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            runner.cancel()
            task.cancel()
        }
        return task
    }
}
