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
            let id = center.start(title: title, detail: detail, operationType: .workflow,
                targetBundleURL: destination.url, routeContext: .init(projectURL: projectURL, windowStateScope: windowStateScope))
            let task = Task { @MainActor [weak self] in
                guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
                do {
                    try Task.checkCancellation()
                    _ = try await PrimerOrderExportService().export(selection: draft.selection, metadata: metadata,
                        destinationURL: destination.url, invocationArgv: CommandLine.arguments,
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
        let cliCommand = ["lungfish-cli", "primers", "scheme-from-analysis", analysisURL.path,
            "--result-id", candidate.resultID.uuidString, "--output", name, "--project", projectURL.path]
        let id = center.start(title: title, detail: "Verifying saved \(candidate.engine) result…", operationType: .workflow,
            targetBundleURL: destination, cliCommand: cliCommand.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "),
            routeContext: route)
        let request = PrimerSchemeFromAnalysisRequest(analysisURL: analysisURL, resultID: candidate.resultID,
            outputURL: URL(fileURLWithPath: name), projectURL: projectURL, displayName: nil,
            argv: CommandLine.arguments, workflowName: "lungfish primers scheme-from-analysis",
            toolVersion: LungfishAppVersion.cliToolVersion)
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
            let id = center.start(title: title, detail: "Verifying saved primer analysis…", operationType: .workflow,
                targetBundleURL: destination.url, routeContext: route)
            let task = Task { @MainActor [weak self] in
                guard center.items.first(where: { $0.id == id })?.state.isActive == true else { return }
                do {
                    try Task.checkCancellation()
                    _ = try await PrimerAnalysisSelectionExportService().export(
                        analysisURL: analysisURL, selection: selection, kind: kind,
                        destinationURL: destination.url, invocationArgv: CommandLine.arguments,
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
            (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Export Primer Selection"
            alert.informativeText = error.localizedDescription
            if let window = view.window { alert.beginSheetModal(for: window) }
        }
    }
}
