import AppKit
import Foundation
import LungfishKit

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
        viewerController.displayPrimerAnalysisBundle(at: url, onLoadStateChanged: { [weak self] state in
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
        inspectorController.beginPrimerAnalysisDocument(at: url)
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
