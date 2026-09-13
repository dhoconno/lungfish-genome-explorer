import Foundation
import LungfishIO

extension InspectorViewController {
    func beginPrimerAnalysisDocument(at url: URL, displaySession: PrimerAnalysisDisplaySession? = nil) {
        viewModel.primerAnalysisDisplaySession?.cancel()
        viewModel.primerAnalysisDisplaySession = displaySession
        viewModel.primerAnalysisDocument = .init(bundleURL: url.standardizedFileURL)
        viewModel.selectedItem = url.deletingPathExtension().lastPathComponent
        viewModel.selectedType = "Primer Analysis"
        viewModel.provenanceSectionViewModel.clear()
        viewModel.selectedTab = .bundle
    }

    func updatePrimerAnalysisDocument(_ snapshot: PrimerAnalysisViewerSnapshot) {
        let bundle = snapshot.bundle
        guard viewModel.primerAnalysisDocument?.bundleURL == bundle.url.standardizedFileURL else { return }
        do {
            let artifacts = bundle.manifest.artifacts + [bundle.manifest.provenance]
            let files = try artifacts.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
                .map { artifact in
                    PrimerAnalysisInspectorFile(artifact: artifact,
                        url: try bundle.artifactURL(forRelativePath: artifact.relativePath))
                }
            viewModel.primerAnalysisDocument = .init(
                bundleURL: bundle.url.standardizedFileURL, isLoading: false,
                grouping: snapshot.groupingLabel, inputCount: bundle.manifest.inputs.count,
                resultCount: bundle.manifest.results.count,
                toolDescriptions: Array(Set(snapshot.toolProvenance.map { "\($0.toolName) \($0.toolVersion)" })).sorted(),
                files: files)
            let canonicalURL = try bundle.artifactURL(forRelativePath: bundle.manifest.provenance.relativePath)
            var sources: [ProvenanceSource] = [.init(id: canonicalURL.path, name: "Analysis", item: .init(
                url: bundle.url, sidebarType: .primerAnalysisBundle, contentMode: viewModel.contentMode,
                displayName: bundle.url.deletingPathExtension().lastPathComponent),
                verifiedRecord: .init(envelope: snapshot.provenance, sidecarURL: canonicalURL))]
            let toolArtifacts = bundle.manifest.artifacts.filter { $0.role == "toolProvenance" }
            let derivedArtifacts = bundle.manifest.artifacts.filter { $0.role == "derivedProvenance" }
            let workflowArtifacts = bundle.manifest.artifacts.filter { $0.role == "workflowProvenance" }
            let recordedProvenance = Array(zip(toolArtifacts, snapshot.toolProvenance))
                + Array(zip(workflowArtifacts, snapshot.workflowProvenance))
                + Array(zip(derivedArtifacts, snapshot.derivedProvenance))
            for (index, entry) in recordedProvenance.enumerated() {
                let sidecarURL = try bundle.artifactURL(forRelativePath: entry.0.relativePath)
                sources.append(.init(id: sidecarURL.path, name: "\(index + 1). \(entry.1.toolName)",
                    item: .init(url: sidecarURL, sidebarType: .primerAnalysisBundle,
                        contentMode: viewModel.contentMode, displayName: entry.1.toolName),
                    verifiedRecord: .init(envelope: entry.1, sidecarURL: sidecarURL)))
            }
            viewModel.provenanceSectionViewModel.configureVerifiedSources(sources)
            viewModel.reconcileSelectedTab()
        } catch {
            failPrimerAnalysisDocument(at: bundle.url, message: error.localizedDescription)
        }
    }

    func failPrimerAnalysisDocument(at url: URL, message: String) {
        guard viewModel.primerAnalysisDocument?.bundleURL == url.standardizedFileURL else { return }
        // Retry reuses the viewer's session. Invalidate its data without disconnecting it.
        viewModel.primerAnalysisDisplaySession?.invalidate()
        viewModel.primerAnalysisDocument = .init(bundleURL: url.standardizedFileURL,
            isLoading: false, errorMessage: message)
        viewModel.provenanceSectionViewModel.presentUnavailableVerifiedRecord(item: .init(
            url: url, sidebarType: .primerAnalysisBundle, contentMode: viewModel.contentMode,
            displayName: url.deletingPathExtension().lastPathComponent), message: message)
        viewModel.reconcileSelectedTab()
    }

    func clearPrimerAnalysisDocument(matching url: URL? = nil) {
        guard let document = viewModel.primerAnalysisDocument,
            url == nil || document.bundleURL == url?.standardizedFileURL else { return }
        viewModel.primerAnalysisDocument = nil
        viewModel.primerAnalysisDisplaySession?.cancel()
        viewModel.primerAnalysisDisplaySession = nil
        viewModel.provenanceSectionViewModel.clear()
        viewModel.reconcileSelectedTab()
    }
}
