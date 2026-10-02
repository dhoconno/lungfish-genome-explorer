import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension MainSplitViewController {
    func displayPrimerAnalysisBundleFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "primerAnalysisBundle")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
        let projectURL = projectSession.projectURL ?? sidebarController.currentProjectURL
        var exportAction: (@MainActor (PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)?
        if let projectURL, ProjectSession.contains(url, in: projectURL) {
            exportAction = { [weak self] selection, kind in
                guard let self,
                    self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                self.exportPrimerAnalysisSelection(at: url, projectURL: projectURL, selection: selection, kind: kind)
            }
        }
        inspectorController.clearSelection()
        let displaySession = PrimerAnalysisDisplaySession(preferences: primerAnalysisDisplayPreferences)
        if let projectURL, ProjectSession.contains(url, in: projectURL), !projectSession.isReadOnlyRecommended {
            displaySession.onOrderExportRequested = { [weak self] draft, metadata in
                guard let self, self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                self.exportDisplayedPrimerOrder(draft, metadata: metadata, projectURL: projectURL)
            }
            displaySession.onSchemeExportRequested = { [weak self] candidate, name in
                guard let self, self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                self.savePrimerScheme(from: url, candidate: candidate, name: name, projectURL: projectURL)
            }
        }
        viewerController.displayPrimerAnalysisBundle(at: url, displaySession: displaySession, onLoadStateChanged: { [weak self] state in
            guard let self, self.canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
            switch state {
            case .loading: break
            case .loaded(let snapshot): self.inspectorController.updatePrimerAnalysisDocument(snapshot)
            case .failed(let message): self.inspectorController.failPrimerAnalysisDocument(at: url, message: message)
            }
        }, onDismiss: { [weak self] in
            self?.inspectorController.clearPrimerAnalysisDocument(matching: url)
        }, onExportRequested: exportAction)
        // clearViewport() during installation tears down the previous inspector before
        // establishing the new scope. The verified load callback commits only to this scope.
        inspectorController.beginPrimerAnalysisDocument(at: url, displaySession: displaySession)
    }

    func displayPrimerOrderFromSidebar(at url: URL, identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil) {
        let identity = identity ?? contentSelectionIdentity(url: url, kind: "primerOrder")
        let token = token ?? beginDisplayRequest(identity: identity)
        guard canCommitDisplayRequest(token, identity: identity) else { return }
        inspectorController.clearSelection()
        viewerController.displayPrimerOrder(at: url, onLoaded: { [weak self] order in
            guard let self, self.canCommitDisplayRequest(token, identity: identity) else { return }
            self.inspectorController.updatePrimerOrderDocument(order, at: url)
        }, onLoadFailed: { [weak self] message in
            guard let self, self.canCommitDisplayRequest(token, identity: identity) else { return }
            self.inspectorController.failPrimerAnalysisDocument(at: url, message: message)
        }, onDismiss: { [weak self] in self?.inspectorController.clearPrimerAnalysisDocument(matching: url) })
        inspectorController.beginPrimerOrderDocument(at: url)
    }

    private func exportDisplayedPrimerOrder(_ draft: PrimerOrderDraft, metadata: PrimerOrderMetadata, projectURL: URL) {
        let normalized = draft.selection.selectedAssayIDs != nil
        let title = draft.selection.isPrimer3CandidateSelection ? "Export Candidate Pairs" : normalized
            ? (draft.selection.includesAllReportedAssays == true ? "Export All Reported Assays" : "Export Selected Assays")
            : "Export Displayed Primer Order"
        guard (projectSession.projectURL ?? sidebarController.currentProjectURL)?.standardizedFileURL == projectURL.standardizedFileURL,
            ProjectSession.contains(draft.selection.analysisURL, in: projectURL), canWriteProjectOutputs(workflowName: title) else { return }
        do {
            let destination = try PrimerAnalysisExportDestination(projectURL: projectURL, name: metadata.name, kind: .primerOrder)
            let center = OperationCenter.shared
            let detail = draft.selection.isPrimer3CandidateSelection ? "Verifying \(draft.oligos.count) candidate oligos…"
                : normalized ? "Verifying \(draft.oligos.count) saved assay oligos…"
                : "Verifying \(draft.oligos.count) displayed oligos…"
            Self.beginPrimerOrderExportOperation(title: title, detail: detail, draft: draft, metadata: metadata,
                destinationURL: destination.url,
                routeContext: .init(projectURL: projectURL, windowStateScope: windowStateScope)) { id in
                let task = Task { @MainActor [weak self] in
                    guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
                    do {
                        try Task.checkCancellation()
                        _ = try await PrimerOrderExportService().export(selection: draft.selection, metadata: metadata,
                            destinationURL: destination.url,
                            invocationArgv: Self.primerOrderExportProvenanceArgv(draft: draft, metadata: metadata,
                                destinationURL: destination.url),
                            progress: { fraction, message in
                                Task { @MainActor in center.updateWithLog(id: id, progress: fraction, detail: message) }
                            }, publish: { [weak self] stagedURL, finalURL in
                                try await MainActor.run {
                                    try PrimerAnalysisExportPublication.commit(stagedURL: stagedURL, destinationURL: finalURL,
                                        center: center, operationID: id) {
                                        guard let self,
                                            (self.projectSession.projectURL ?? self.sidebarController.currentProjectURL)?.standardizedFileURL == projectURL.standardizedFileURL,
                                            !self.projectSession.isReadOnlyRecommended else { throw CancellationError() }
                                        try destination.validateBeforePublication()
                                    }
                                    self?.sidebarController.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
                                }
                            })
                    } catch is CancellationError { center.acknowledgeCancellation(id: id) }
                    catch { center.fail(id: id, detail: "Primer order export failed.", errorMessage: error.localizedDescription,
                        errorDetail: String(reflecting: error)) }
                }
                center.setCancelCallback(for: id) { task.cancel() }
            }
            (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Export Primer Order"
            alert.informativeText = error.localizedDescription
            if let window = view.window { alert.beginSheetModal(for: window) }
        }
    }

    /// Writes the chosen result as a `.lungfishprimers` bundle in the project's Primer Schemes folder.
    /// The service refuses an existing bundle name, so nothing a trim already used is replaced.
    private func savePrimerScheme(from analysisURL: URL, candidate: PrimerSchemeFromAnalysisCandidate,
        name: String, projectURL: URL) {
        let title = "Save as Primer Scheme"
        guard (projectSession.projectURL ?? sidebarController.currentProjectURL)?.standardizedFileURL == projectURL.standardizedFileURL,
            ProjectSession.contains(analysisURL, in: projectURL), canWriteProjectOutputs(workflowName: title) else { return }
        let center = OperationCenter.shared
        let schemesFolder = projectURL.appendingPathComponent(PrimerSchemesFolder.folderName, isDirectory: true)
        let destination = schemesFolder.appendingPathComponent(name + ".lungfishprimers", isDirectory: true)
        let route = OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)
        // begin(...) refuses a conflicting bundle lock and inserts the visible
        // "Bundle is busy" row itself, so nothing is launched on refusal.
        guard let id = center.begin(title: title, detail: "Verifying saved \(candidate.engine) result…", operationType: .workflow,
            targetBundleURL: destination,
            cliCommand: Self.primerSchemeSaveCLICommand(analysisURL: analysisURL, resultID: candidate.resultID,
                name: name, projectURL: projectURL),
            routeContext: route).startedID else { return }
        let request = Self.primerSchemeSaveRequest(analysisURL: analysisURL, resultID: candidate.resultID,
            name: name, projectURL: projectURL)
        let task = Task { @MainActor [weak self] in
            guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
            do {
                try Task.checkCancellation()
                center.updateWithLog(id: id, progress: 0.2, detail: "Coordinates belong to \(candidate.referenceID).")
                let worker = Task.detached(priority: .userInitiated) {
                    try PrimerSchemeFromAnalysisService.export(request: request)
                }
                let result = try await withTaskCancellationHandler(operation: { try await worker.value },
                    onCancel: { worker.cancel() })
                guard let self, !self.projectSession.isReadOnlyRecommended else { throw CancellationError() }
                center.updateWithLog(id: id, progress: 0.95, detail: "Primer scheme written to \(result.bundleURL.lastPathComponent).")
                center.complete(id: id, detail: "Saved in the project's Primer Schemes folder. \(candidate.referenceStatement)",
                    outputURLs: [result.bundleURL])
                self.sidebarController.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
            } catch is CancellationError { center.acknowledgeCancellation(id: id) }
            catch { center.fail(id: id, detail: "Primer scheme export failed.", errorMessage: error.localizedDescription,
                errorDetail: String(reflecting: error)) }
        }
        center.setCancelCallback(for: id) { task.cancel() }
        (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
    }

    private func exportPrimerAnalysisSelection(at analysisURL: URL, projectURL: URL,
        selection: PrimerAnalysisExportSelection, kind: PrimerAnalysisExportKind) {
        let title = kind == .primerFASTA ? "Save Primer FASTA Bundle" : "Extract Reference Amplicon"
        guard (projectSession.projectURL ?? sidebarController.currentProjectURL)?.standardizedFileURL == projectURL.standardizedFileURL,
            ProjectSession.contains(analysisURL, in: projectURL), canWriteProjectOutputs(workflowName: title) else { return }
        do {
            let suffix = kind == .primerFASTA ? "primers" : "reference amplicon"
            let destination = try PrimerAnalysisExportDestination(projectURL: projectURL,
                name: analysisURL.deletingPathExtension().lastPathComponent + " " + suffix)
            let route = OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)
            let center = OperationCenter.shared
            Self.beginPrimerAnalysisSelectionExportOperation(title: title, destinationURL: destination.url,
                routeContext: route) { id in
                let task = Task { @MainActor [weak self] in
                    guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
                    do {
                        try Task.checkCancellation()
                        _ = try await PrimerAnalysisSelectionExportService().export(
                            analysisURL: analysisURL, selection: selection, kind: kind,
                            destinationURL: destination.url,
                            invocationArgv: Self.primerSelectionExportProvenanceArgv(analysisURL: analysisURL,
                                selection: selection, kind: kind, destinationURL: destination.url),
                            progress: { fraction, message in
                                Task { @MainActor in center.updateWithLog(id: id, progress: fraction, detail: message) }
                            }, publish: { [weak self] stagedURL, finalURL in
                                try await MainActor.run {
                                    try PrimerAnalysisExportPublication.commit(stagedURL: stagedURL,
                                        destinationURL: finalURL, center: center, operationID: id) {
                                        guard let self, (self.projectSession.projectURL ?? self.sidebarController.currentProjectURL)?.standardizedFileURL == projectURL.standardizedFileURL,
                                            !self.projectSession.isReadOnlyRecommended else { throw CancellationError() }
                                        try destination.validateBeforePublication()
                                    }
                                    self?.sidebarController.requestReloadFromFilesystem(notifyUnchangedSelectionRefresh: false)
                                }
                            })
                    } catch is CancellationError { center.acknowledgeCancellation(id: id) }
                    catch { center.fail(id: id, detail: "Primer export failed.", errorMessage: error.localizedDescription,
                        errorDetail: String(reflecting: error)) }
                }
                center.setCancelCallback(for: id) { task.cancel() }
            }
            (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Export Primer Selection"
            alert.informativeText = error.localizedDescription
            if let window = view.window { alert.beginSheetModal(for: window) }
        }
    }

    // MARK: - Operations panel registration (finding R4)

    /// Registers the primer order export row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks the new order folder,
    /// `destinationURL`, and records the command
    /// ``primerOrderExportCLICommand(draft:metadata:destinationURL:)`` builds.
    @discardableResult
    static func beginPrimerOrderExportOperation(
        title: String,
        detail: String,
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL,
        routeContext: OperationRouteContext,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: detail,
            operationType: .workflow,
            targetBundleURL: destinationURL,
            cliCommand: primerOrderExportCLICommand(draft: draft, metadata: metadata, destinationURL: destinationURL),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The `lungfish-cli primers analysis export-order` command that reproduces
    /// a primer order export, or nil when no command does.
    ///
    /// The command names the scope the draft captured. A Primer3 draft names
    /// its candidate pairs, an Olivar or varVAMP draft names selected or all
    /// reported assays, and a PrimalScheme draft names the displayed oligos.
    /// The CLI captures the default view, so a PrimalScheme draft whose view
    /// settings differ from the defaults has no command that reproduces it.
    /// That is a CLI parity gap, and the row records no command for it. The
    /// other scopes ignore the view settings.
    static func primerOrderExportCLICommand(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> String? {
        primerOrderExportCLIArguments(draft: draft, metadata: metadata, destinationURL: destinationURL).map {
            OperationCenter.buildCLICommand(subcommand: "primers analysis export-order", args: $0)
        }
    }

    /// The arguments after `lungfish-cli primers analysis export-order` for a
    /// primer order export, or nil when no command reproduces it. The row
    /// command and the provenance argv are both built from this list.
    static func primerOrderExportCLIArguments(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> [String]? {
        guard let scope = primerOrderExportScopeArguments(draft.selection, includesViewSettings: false) else {
            return nil
        }
        return [draft.selection.analysisURL.path, "--output", destinationURL.path] + scope
            + primerOrderMetadataArguments(metadata)
    }

    /// The argv the order's provenance records (findings R3 and R8). It is the
    /// `lungfish-cli primers analysis export-order` command the row records,
    /// as words. A PrimalScheme order from a filtered view has no command, so
    /// its argv names the app and the filtered view, as the app's other
    /// exports do with `Lungfish.app <action>`. It used to be the app
    /// process's own launch arguments, which named no export at all.
    static func primerOrderExportProvenanceArgv(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> [String] {
        if let arguments = primerOrderExportCLIArguments(
            draft: draft, metadata: metadata, destinationURL: destinationURL
        ) {
            return [CLICommandIdentity.executableName, "primers", "analysis", "export-order"] + arguments
        }
        let scope = primerOrderExportScopeArguments(draft.selection, includesViewSettings: true) ?? []
        return ["Lungfish.app", "export-primer-order", draft.selection.analysisURL.path,
                "--output", destinationURL.path] + scope + primerOrderMetadataArguments(metadata)
    }

    /// The `--scope` arguments for the captured selection, or nil for a
    /// PrimalScheme view that is not the default one, unless
    /// `includesViewSettings` asks for that view to be named as `--view filtered`.
    private static func primerOrderExportScopeArguments(
        _ selection: PrimerOrderSelection,
        includesViewSettings: Bool
    ) -> [String]? {
        if selection.isPrimer3CandidateSelection {
            return ["--scope", "candidate-pairs"]
                + (selection.selectedAssayIDs ?? []).flatMap { ["--candidate-pair-id", $0] }
        }
        if selection.selectedAssayIDs != nil {
            return ["--scope", selection.includesAllReportedAssays == true ? "all-reported-assays" : "selected-assays"]
        }
        if selection.settings == PrimerAnalysisDisplaySettings() {
            return ["--scope", "displayed"]
        }
        return includesViewSettings ? ["--scope", "displayed", "--view", "filtered"] : nil
    }

    /// `--name` and the order fields the user filled in. `--name` is always
    /// passed because the CLI's default name differs from the app's.
    private static func primerOrderMetadataArguments(_ metadata: PrimerOrderMetadata) -> [String] {
        var args = ["--name", metadata.name]
        let optionalFields = [
            ("--requested-by", metadata.requestedBy),
            ("--project", metadata.project),
            ("--order-reference", metadata.orderReference),
            ("--notes", metadata.notes),
        ]
        for (flag, value) in optionalFields where !value.isEmpty {
            args += [flag, value]
        }
        return args
    }

    /// The arguments after `lungfish-cli primers scheme-from-analysis` that
    /// save result `resultID` of the analysis at `analysisURL` as the scheme
    /// `name` in the project's Primer Schemes folder, the save
    /// `savePrimerScheme` runs (findings R3 and R8). The row command and the
    /// scheme's provenance argv are both built from this list. The name is
    /// joined to `--output`, so the parser reads a name that starts with a
    /// hyphen as a value.
    static func primerSchemeSaveCLIArguments(
        analysisURL: URL,
        resultID: UUID,
        name: String,
        projectURL: URL
    ) -> [String] {
        [analysisURL.path, "--result-id", resultID.uuidString, "--output=\(name)", "--project", projectURL.path]
    }

    /// The `lungfish-cli primers scheme-from-analysis` command the Save as
    /// Primer Scheme row records, quoted by `OperationCenter.buildCLICommand`.
    /// The row used to quote only the words that held a space, so a name with
    /// an apostrophe gave a command no shell could read.
    static func primerSchemeSaveCLICommand(
        analysisURL: URL,
        resultID: UUID,
        name: String,
        projectURL: URL
    ) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "primers scheme-from-analysis",
            args: primerSchemeSaveCLIArguments(
                analysisURL: analysisURL, resultID: resultID, name: name, projectURL: projectURL
            )
        )
    }

    /// The request `savePrimerScheme` hands `PrimerSchemeFromAnalysisService`.
    /// It names the output and the project as the recorded command does, and
    /// its argv, which the scheme's provenance records, is that command as
    /// words. The argv used to be the app process's own launch arguments,
    /// which named no save at all.
    static func primerSchemeSaveRequest(
        analysisURL: URL,
        resultID: UUID,
        name: String,
        projectURL: URL
    ) -> PrimerSchemeFromAnalysisRequest {
        PrimerSchemeFromAnalysisRequest(
            analysisURL: analysisURL,
            resultID: resultID,
            outputURL: URL(fileURLWithPath: name),
            projectURL: projectURL,
            displayName: nil,
            argv: [CLICommandIdentity.executableName, "primers", "scheme-from-analysis"]
                + primerSchemeSaveCLIArguments(
                    analysisURL: analysisURL, resultID: resultID, name: name, projectURL: projectURL
                ),
            workflowName: "lungfish primers scheme-from-analysis",
            toolVersion: LungfishAppVersion.cliToolVersion
        )
    }

    /// The argv the provenance of a primer FASTA bundle or reference amplicon
    /// export records (findings R3 and R8). No `lungfish-cli` command exports
    /// a selection, so the argv names the app, as the app's other exports do
    /// with `Lungfish.app <action>`, and lists the analysis, the export kind,
    /// the selected primer, amplicon or pool and the output bundle. It used to
    /// be the app process's own launch arguments.
    static func primerSelectionExportProvenanceArgv(
        analysisURL: URL,
        selection: PrimerAnalysisExportSelection,
        kind: PrimerAnalysisExportKind,
        destinationURL: URL
    ) -> [String] {
        let selectionArguments: [String]
        switch selection {
        case .primer(let targetID, let primerID):
            selectionArguments = ["--target-id", targetID, "--primer-id", primerID]
        case .amplicon(let targetID, let ampliconID):
            selectionArguments = ["--target-id", targetID, "--amplicon-id", ampliconID]
        case .pool(let sourceResultID, let pool):
            selectionArguments = ["--source-result-id", sourceResultID, "--pool", String(pool)]
        case .nativePool(let sourceResultID, let pool):
            selectionArguments = ["--source-result-id", sourceResultID, "--native-pool", pool]
        }
        return ["Lungfish.app", "export-primer-selection", analysisURL.path, "--kind", kind.rawValue]
            + selectionArguments + ["--output", destinationURL.path]
    }

    /// Registers the primer selection export row ("Save Primer FASTA Bundle"
    /// or "Extract Reference Amplicon") and, only when it starts, calls
    /// `launch` with the operation ID. The row locks the new export folder,
    /// `destinationURL`, and records no command.
    ///
    /// CLI parity gap. No lungfish-cli command writes a primer FASTA bundle or
    /// extracts the reference amplicon for a selected primer, amplicon or
    /// pool. The closest is `primers analysis annotated-reference`, which
    /// writes the whole Primer3 template of one result as an annotated
    /// reference bundle. The row keeps recording no command until a selection
    /// export command exists.
    @discardableResult
    static func beginPrimerAnalysisSelectionExportOperation(
        title: String,
        destinationURL: URL,
        routeContext: OperationRouteContext,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Verifying saved primer analysis…",
            operationType: .workflow,
            targetBundleURL: destinationURL,
            cliCommand: nil,
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }
}
