import Foundation
import LungfishIO
import LungfishWorkflow

extension InspectorViewController {
    func beginPrimerOrderDocument(at url: URL) {
        beginPrimerAnalysisDocument(at: url)
        viewModel.primerAnalysisDocument?.isOrder = true
        viewModel.selectedType = "Primer Order"
    }

    func updatePrimerOrderDocument(_ snapshot: PrimerOrderViewerSnapshot, at url: URL) {
        guard viewModel.primerAnalysisDocument?.bundleURL == url.standardizedFileURL else { return }
        let order = snapshot.document, envelope = snapshot.provenance
        var uniquePaths: Set<String> = []
        let files = envelope.outputs.compactMap { output -> PrimerAnalysisInspectorFile? in
            guard output.path.hasPrefix(order.outputDirectoryPath + "/"),
                let checksum = output.checksumSHA256, let size = output.fileSize else { return nil }
            let path = String(output.path.dropFirst(order.outputDirectoryPath.count + 1))
            guard uniquePaths.insert(path).inserted else { return nil }
            return .init(artifact: .init(relativePath: path,
                role: path.hasPrefix("source-analysis/") ? "source evidence" : "order output",
                format: URL(fileURLWithPath: path).pathExtension, sha256: checksum, byteSize: size),
                url: url.appendingPathComponent(path))
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        viewModel.primerAnalysisDocument = .init(bundleURL: url.standardizedFileURL, isLoading: false,
            files: files, order: order, isOrder: true)
        let canonicalURL = url.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        viewModel.provenanceSectionViewModel.configureVerifiedSources([.init(id: canonicalURL.path, name: "Primer order",
            item: .init(url: url, sidebarType: .analysisResult, contentMode: viewModel.contentMode, displayName: order.metadata.name),
            verifiedRecord: .init(envelope: envelope, sidecarURL: canonicalURL))])
        viewModel.reconcileSelectedTab()
    }
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
        let isOrder = viewModel.primerAnalysisDocument?.isOrder == true
        // Retry reuses the viewer's session. Invalidate its data without disconnecting it.
        viewModel.primerAnalysisDisplaySession?.invalidate()
        viewModel.primerAnalysisDocument = .init(bundleURL: url.standardizedFileURL,
            isLoading: false, errorMessage: message, isOrder: isOrder)
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
