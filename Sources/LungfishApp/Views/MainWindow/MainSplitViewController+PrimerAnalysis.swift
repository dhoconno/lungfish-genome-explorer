import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
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
                            invocationArgv: PrimerOrderExport.primerOrderExportProvenanceArgv(draft: draft, metadata: metadata,
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
                cliCommand: Self.primerSelectionExportCLICommand(analysisURL: analysisURL, selection: selection,
                    kind: kind, destinationURL: destination.url),
                routeContext: route) { id in
                let task = Task { @MainActor [weak self] in
                    guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
                    do {
                        try Task.checkCancellation()
                        _ = try await PrimerAnalysisSelectionExportService().export(
                            analysisURL: analysisURL, selection: selection, kind: kind,
                            destinationURL: destination.url,
                            invocationArgv: PrimerSelectionExport.primerSelectionExportProvenanceArgv(analysisURL: analysisURL,
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
    /// a primer order export.
    ///
    /// The command names the scope the draft captured. A Primer3 draft names
    /// its candidate pairs, an Olivar or varVAMP draft names selected or all
    /// reported assays, and a PrimalScheme draft names the displayed oligos
    /// with the view options that reproduce its view, none for the default
    /// view. The other scopes ignore the view settings.
    static func primerOrderExportCLICommand(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "primers analysis export-order",
            args: PrimerOrderExport.primerOrderExportCLIArguments(draft: draft, metadata: metadata, destinationURL: destinationURL)
        )
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

    /// The `lungfish-cli primers analysis export-selection` command that reproduces a primer FASTA bundle or
    /// a reference amplicon export (lane 12.15, A67-M3). The row records it and the export's provenance argv
    /// is its words. The app keeps its in-process writer, which is the service the command calls.
    static func primerSelectionExportCLICommand(
        analysisURL: URL,
        selection: PrimerAnalysisExportSelection,
        kind: PrimerAnalysisExportKind,
        destinationURL: URL
    ) -> String {
        OperationCenter.buildCLICommand(
            subcommand: "primers analysis export-selection",
            args: PrimerSelectionExport.primerSelectionExportCLIArguments(
                analysisURL: analysisURL, selection: selection, kind: kind, destinationURL: destinationURL
            )
        )
    }

    /// Registers the primer selection export row ("Save Primer FASTA Bundle" or "Extract Reference
    /// Amplicon") and, only when it starts, calls `launch` with the operation ID. The row locks the new
    /// export folder, `destinationURL`, and records `cliCommand`, which
    /// ``primerSelectionExportCLICommand(analysisURL:selection:kind:destinationURL:)`` builds. `cliCommand`
    /// has no default, so a caller cannot leave the row without one.
    @discardableResult
    static func beginPrimerAnalysisSelectionExportOperation(
        title: String,
        destinationURL: URL,
        cliCommand: String,
        routeContext: OperationRouteContext,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: "Verifying saved primer analysis…",
            operationType: .workflow,
            targetBundleURL: destinationURL,
            cliCommand: cliCommand,
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

extension PrimerOrderExport {
    /// The arguments after `lungfish-cli primers analysis export-order` for a
    /// primer order export. The row command and the provenance argv are both
    /// built from this list.
    public static func primerOrderExportCLIArguments(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> [String] {
        [draft.selection.analysisURL.path, "--output", destinationURL.path]
            + primerOrderExportScopeArguments(draft.selection) + primerOrderMetadataArguments(metadata)
    }

    /// The argv the order's provenance records (findings R3 and R8). It is the
    /// `lungfish-cli primers analysis export-order` command the row records,
    /// as words, for every order including one from a filtered PrimalScheme view.
    public static func primerOrderExportProvenanceArgv(
        draft: PrimerOrderDraft,
        metadata: PrimerOrderMetadata,
        destinationURL: URL
    ) -> [String] {
        [CLICommandIdentity.executableName, "primers", "analysis", "export-order"]
            + primerOrderExportCLIArguments(draft: draft, metadata: metadata, destinationURL: destinationURL)
    }

    /// The `--scope` arguments for the captured selection, and for a PrimalScheme
    /// selection the view options of its view.
    private static func primerOrderExportScopeArguments(_ selection: PrimerOrderSelection) -> [String] {
        if selection.isPrimer3CandidateSelection {
            return ["--scope", "candidate-pairs"]
                + (selection.selectedAssayIDs ?? []).flatMap { ["--candidate-pair-id", $0] }
        }
        if selection.selectedAssayIDs != nil {
            return ["--scope", selection.includesAllReportedAssays == true ? "all-reported-assays" : "selected-assays"]
        }
        return ["--scope", "displayed"] + primerOrderViewArguments(selection.settings)
    }

    /// The view options of `export-order` that reproduce `settings`, none for the
    /// default view. They name every field of the settings that differs from the
    /// default, so the order records the same view as the app's.
    private static func primerOrderViewArguments(_ settings: PrimerAnalysisDisplaySettings) -> [String] {
        var args = settings.hiddenPrimerIDs.sorted().flatMap { ["--hide-primer", $0] }
        args += settings.hiddenPoolIDs.sorted().flatMap { ["--hide-pool", $0] }
        if !settings.showForward { args.append("--hide-forward") }
        if !settings.showReverse { args.append("--hide-reverse") }
        if !settings.showAmplicons { args.append("--hide-amplicons") }
        if !settings.showIdentityDots { args.append("--hide-identity-dots") }
        if !settings.showUnassessed { args.append("--hide-unassessed") }
        if settings.filterByCompatibility { args.append("--filter-compatibility") }
        if settings.minimumCompatibilityPercent != 0 {
            args += ["--min-compatibility", String(settings.minimumCompatibilityPercent)]
        }
        return args
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
}

extension PrimerSelectionExport {
    /// The arguments after `lungfish-cli primers analysis export-selection` for a primer FASTA bundle or a
    /// reference amplicon export. The row command and the provenance argv are both built from this list.
    /// The values the saved analysis supplies (the IDs and a native pool name) join their option with `=`,
    /// so the parser reads one that starts with a hyphen as a value.
    public static func primerSelectionExportCLIArguments(
        analysisURL: URL,
        selection: PrimerAnalysisExportSelection,
        kind: PrimerAnalysisExportKind,
        destinationURL: URL
    ) -> [String] {
        let selectionArguments: [String]
        switch selection {
        case .primer(let targetID, let primerID):
            selectionArguments = ["--target-id=\(targetID)", "--primer-id=\(primerID)"]
        case .amplicon(let targetID, let ampliconID):
            selectionArguments = ["--target-id=\(targetID)", "--amplicon-id=\(ampliconID)"]
        case .pool(let sourceResultID, let pool):
            selectionArguments = ["--source-result-id=\(sourceResultID)", "--pool", String(pool)]
        case .nativePool(let sourceResultID, let pool):
            selectionArguments = ["--source-result-id=\(sourceResultID)", "--native-pool=\(pool)"]
        }
        let kindName: String
        switch kind {
        case .primerFASTA: kindName = "primer-fasta"
        case .referenceAmplicon: kindName = "reference-amplicon"
        }
        return [analysisURL.path, "--kind", kindName] + selectionArguments + ["--output", destinationURL.path]
    }

    /// The argv the provenance of a primer FASTA bundle or reference amplicon export records (findings R3
    /// and R8). It is the `lungfish-cli primers analysis export-selection` command the row records, as
    /// words. It used to name `Lungfish.app export-primer-selection`, a command that no binary has.
    public static func primerSelectionExportProvenanceArgv(
        analysisURL: URL,
        selection: PrimerAnalysisExportSelection,
        kind: PrimerAnalysisExportKind,
        destinationURL: URL
    ) -> [String] {
        [CLICommandIdentity.executableName, "primers", "analysis", "export-selection"]
            + primerSelectionExportCLIArguments(
                analysisURL: analysisURL, selection: selection, kind: kind, destinationURL: destinationURL
            )
    }
}
