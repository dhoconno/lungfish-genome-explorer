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
    /// Names the operation that carries the run, which the pane reads to see that a cancelled run has ended.
    var began: (@MainActor @Sendable (UUID) -> Void)? = nil
    /// Shows a search that has gone out and has no result, from its file, whether its process runs on or has parked.
    var waiting: (@MainActor @Sendable (BlastLiveSearch) -> Void)? = nil

    /// The drawer of a viewer on `ClassifierResultActions`. Every word names its run, so a result lands on the row the
    /// run was sent for, whichever row is picked and however many searches are out.
    @MainActor
    static func classifier(_ actions: @escaping @MainActor @Sendable () -> ClassifierResultActions?) -> BlastSubmitDrawer {
        let run = BlastDrawerRun()
        return BlastSubmitDrawer(
            loading: { actions()?.showBlastLoading(phase: $0, requestId: nil, run: run.id) },
            results: { actions()?.showBlastResults($0, recordURL: $1, run: run.id) },
            failure: { actions()?.showBlastFailure($0, run: run.id) },
            began: {
                run.id = $0
                actions()?.trackBlastRun(operationID: $0)
            },
            waiting: { actions()?.showBlastWaiting($0, run: run.id) }
        )
    }
}

/// The operation a drawer reports for, known once its row has begun.
@MainActor
final class BlastDrawerRun {
    var id: UUID?
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

    /// Asks before `noun` leaves this Mac, on a route with no popover. Every such route searches `core_nt`, as
    /// `BlastSubmitPlan.make` and the FASTA runner set (UX-BLAST-WORDS Q4).
    func askBeforeBlastSend(noun: String, send: @escaping @MainActor () -> Void) {
        BlastConsentSheet.ask(
            line: BlastSearchWords.consentLine(noun: noun, database: BlastDatabaseID.coreNT.rawValue),
            window: view.window,
            send: send
        )
    }

    /// `send`, once the person has answered the consent line.
    func withBlastConsent(noun: String, _ send: @escaping () -> Void) -> () -> Void {
        { [weak self] in self?.askBeforeBlastSend(noun: noun) { send() } }
    }

    /// `send`, once the person has answered the consent line.
    func withBlastConsent<Input>(noun: String, _ send: @escaping (Input) -> Void) -> (Input) -> Void {
        { [weak self] input in self?.askBeforeBlastSend(noun: noun) { send(input) } }
    }

    /// `send`, once the person has answered the consent line.
    func withBlastConsent<First, Second>(noun: String, _ send: @escaping (First, Second) -> Void) -> (First, Second) -> Void {
        { [weak self] first, second in self?.askBeforeBlastSend(noun: noun) { send(first, second) } }
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
        override: FASTABlastVerificationRunner?,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner()
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
            let output = plan.request.outputURL
            BlastInFlightMonitor.shared.viewerRunBegan(output: output, row: operationID)
            defer { BlastInFlightMonitor.shared.viewerRunEnded(output: output) }
            let outcome = try await plan.run(runner: runner) { event in
                bridge(event)
                if case let .progress(fraction, message) = event { progress(fraction, message) }
            }
            let completed = try outcome.collected(output: output)
            return (completed.result, completed.recordURL)
        }
    }

    /// Parks a FASTA row and shows its search waiting. A late result reaches the pane through the list's look-up of the
    /// search for the picked sequences, which the caller starts, so it never shows over other sequences (O1).
    static func parkFASTABlastRow(
        _ operationID: UUID,
        _ parked: BlastSubmitParked,
        controller: FASTACollectionViewController?,
        monitor: BlastInFlightMonitor = .shared
    ) async {
        await parkBlastRow(operationID, words: parked.words, output: parked.output, monitor: monitor) {
            controller?.ensureBlastDrawer().showWaiting($0)
        }
    }

    /// The Cancel of a FASTA row, as ``launchBlastSubmit(_:operationID:runner:drawer:monitor:completeDetail:)`` has it. A
    /// person's Cancel ends the leaf through its task, then stops the search, and the row says so. A quit sends SIGTERM alone,
    /// so the search stays at NCBI. With no plan, a test's runner stands in and no search exists to stop.
    static func setFASTABlastCancel(
        operationID: UUID,
        output: URL?,
        task: Task<Void, Never>,
        stopper: CLIBlastSubmitRunner = CLIBlastSubmitRunner()
    ) {
        OperationCenter.shared.setCancelCallback(for: operationID) {
            cancelFASTABlastRun(operationID: operationID, output: output, task: task, stopper: stopper)
        }
    }

    /// What that Cancel does when OperationCenter runs it, apart so that a test can run it once a quit's `cancelAll()` has
    /// returned, as the callback's own queue does, and wait for the stop it starts. A quit starts none and returns nil.
    @discardableResult
    nonisolated static func cancelFASTABlastRun(
        operationID: UUID,
        output: URL?,
        task: Task<Void, Never>,
        stopper: CLIBlastSubmitRunner
    ) -> Task<Void, Never>? {
        let quitting = OperationCenter.wasCancelledByAQuit(id: operationID)
        task.cancel()
        guard !quitting, let output else { return nil }
        return Task { @MainActor in
            await task.value
            guard FileManager.default.fileExists(atPath: output.appendingPathComponent(BlastSearchFile.fileName).path) else { return }
            OperationCenter.shared.setStoppedWords(id: operationID, words: BlastSearchWords.stopped)
            await stopper.stopSearch(output: output)
            BlastSearchNews.post()
        }
    }

    /// The search in `output`, read off the main actor, since a project's folder can be slow.
    @concurrent nonisolated static func readBlastSearch(in output: URL) async -> BlastLiveSearch? {
        BlastLiveSearch.read(folder: output)
    }

    /// The leaf parked, so the row waits with no process behind it and the monitor goes on with it. It is never failed.
    static func parkBlastRow(
        _ operationID: UUID,
        words: String,
        output: URL,
        monitor: BlastInFlightMonitor = .shared,
        show: @MainActor (BlastLiveSearch) -> Void
    ) async {
        let search = await readBlastSearch(in: output)
        guard OperationCenter.shared.park(id: operationID, detail: words) else {
            monitor.viewerRunEnded(output: output)
            return
        }
        monitor.viewerRunParked(output: output, row: operationID)
        monitor.viewerRunEnded(output: output)
        if let search { show(search) }
        BlastSearchNews.post()
    }

    /// Runs `plan` for the row `operationID` on `runner` (2.11 A65 M2, decision C5 of 2.10). The leaf's
    /// events reach the row through `OperationCenterCLIBridge`, and each one shows the search as its file now stands.
    /// A person's Cancel stops the leaf's whole process tree through the runner and then stops the search, while a quit
    /// sends SIGTERM alone, so the search stays at NCBI. The row completes with `completeDetail` of the verdicts the
    /// record holds, or parks when every send is waiting, and either way every open pane hears of it.
    @discardableResult
    static func launchBlastSubmit(
        _ plan: BlastSubmitPlan,
        operationID: UUID,
        runner: CLIBlastSubmitRunner = CLIBlastSubmitRunner(),
        drawer: BlastSubmitDrawer,
        monitor: BlastInFlightMonitor = .shared,
        completeDetail: @escaping @Sendable (BlastVerificationResult) -> String
    ) -> Task<Void, Never> {
        drawer.began?(operationID)
        drawer.loading(.submitting)
        let output = plan.request.outputURL
        monitor.viewerRunBegan(output: output, row: operationID)
        let onEvent = OperationCenterCLIBridge.onEvent(operationID: operationID) { _ in
            Task { @MainActor in
                guard let waiting = drawer.waiting, let search = await readBlastSearch(in: output),
                      OperationCenter.shared.items.first(where: { $0.id == operationID })?.state == .running else { return }
                waiting(search)
            }
        }
        let task = Task { @MainActor in
            do {
                switch try await plan.run(runner: runner, onEvent: onEvent) {
                case .collected(let result, let recordURL):
                    monitor.viewerRunEnded(output: output)
                    let counts = completeDetail(result)
                    let collected = await readBlastSearch(in: output).flatMap { BlastSearchWords.collected(in: $0.file) }
                    let detail = collected.map { "\(counts). \($0)" } ?? counts
                    guard OperationCenter.shared.complete(id: operationID, detail: detail) else { return }
                    drawer.results(result, recordURL)
                    BlastSearchNews.post()
                case .waiting(let words):
                    await parkBlastRow(operationID, words: words, output: output, monitor: monitor) { drawer.waiting?($0) }
                }
            } catch is CancellationError {
                monitor.viewerRunEnded(output: output)
                OperationCenter.shared.acknowledgeCancellation(id: operationID)
                guard runner.wasStoppedByAPerson,
                      FileManager.default.fileExists(atPath: output.appendingPathComponent(BlastSearchFile.fileName).path) else {
                    BlastSearchNews.post()
                    return
                }
                OperationCenter.shared.setStoppedWords(id: operationID, words: BlastSearchWords.stopped)
                Task { @MainActor in
                    await runner.stopSearch(output: output)
                    BlastSearchNews.post()
                }
            } catch {
                monitor.viewerRunEnded(output: output)
                let errorText = error.localizedDescription
                guard OperationCenter.shared.fail(id: operationID, detail: errorText, errorMessage: errorText) else { return }
                drawer.failure(errorText)
            }
        }
        OperationCenter.shared.setCancelCallback(for: operationID) {
            // A quit is no person's Stop, so the search stays at NCBI and LGE checks it at the next launch.
            let quitting = OperationCenter.wasCancelledByAQuit(id: operationID)
            if quitting { runner.cancel() } else { runner.cancelAsAPersonsStop() }
            task.cancel()
        }
        return task
    }
}
