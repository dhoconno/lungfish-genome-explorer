import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ViewerViewController {
    @discardableResult
    func displayTwelveSAmpliconResult(_ result: TwelveSAmpliconResultBundleData) -> TwelveSAmpliconResultViewController {
        hideQuickLookPreview()
        hideFASTQDatasetView()
        hideVCFDatasetView()
        hideFASTACollectionView()
        hideTaxonomyView()
        hideEsVirituView()
        hideTaxTriageView()
        hideNaoMgsView()
        hideNvdView()
        hideCzIdView()
        hideAssemblyView()
        hideMappingView()
        hideGenotypeResultView()
        hideAlignmentTreeBundleViews()
        clearBundleDisplay()
        hideCollectionBackButton()
        hideBundleBackNavigationButton()
        hideProgress()
        contentMode = .metagenomics

        let controller = TwelveSAmpliconResultViewController()
        addChild(controller)
        controller.onUnresolvedBlastRequested = { [weak controller] request in
            guard let controller else { return }
            let minimumReads = max(0, request.minimumReads)
            controller.showBlastLoading(phase: .submitting, requestId: nil)
            let exportURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("lungfish-12s-blast-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("unresolved-min\(minimumReads).fasta")
            let selectedSequenceIDs = request.sequences.map(\.sequenceID)
            var arguments = [
                "fastq", "12s-export-unresolved",
                "--bundle", request.bundleURL.path,
                "--min-reads", String(minimumReads),
                "--output", exportURL.path,
                "--include-chimera-candidates",
                "--force",
            ]
            for sequenceID in selectedSequenceIDs {
                arguments += ["--sequence-id", sequenceID]
            }
            let cliCommand = ViralReconWorkflowCommandPreview.build(
                executableName: "lungfish-cli",
                arguments: arguments
            )
            let operationID = OperationCenter.shared.start(
                title: "BLAST 12S Unresolved",
                detail: "Preparing unresolved sequence FASTA...",
                operationType: .blastVerification,
                cliCommand: cliCommand
            )
            controller.onUnresolvedBlastCancelRequested = {
                OperationCenter.shared.cancel(id: operationID)
            }

            let task = Task.detached {
                do {
                    try FileManager.default.createDirectory(
                        at: exportURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    _ = try LungfishCLIRunner.run(arguments: arguments)
                    try Self.verifyTwelveSBlastPreparationProvenance(
                        sidecarURL: exportURL.appendingPathExtension("lungfish-provenance.json"),
                        outputURL: exportURL
                    )
                    let sequences = try Self.twelveSBlastSequences(fromFasta: exportURL)
                    guard !sequences.isEmpty else {
                        throw BlastServiceError.noSequences
                    }
                    let blastRequest = BlastVerificationRequest(
                        taxonName: "12S unresolved sequences",
                        taxId: 0,
                        sequences: sequences,
                        database: "core_nt",
                        entrezQuery: nil
                    )
                    let result = try await BlastService.shared.verify(
                        request: blastRequest,
                        progress: { fraction, message in
                            DispatchQueue.main.async {
                                MainActor.assumeIsolated {
                                    OperationCenter.shared.update(id: operationID, progress: fraction, detail: message)
                                    let lower = message.lowercased()
                                    if lower.contains("waiting") {
                                        controller.showBlastLoading(phase: .waiting, requestId: nil)
                                    } else if lower.contains("parsing") {
                                        controller.showBlastLoading(phase: .parsing, requestId: nil)
                                    } else {
                                        controller.showBlastLoading(phase: .submitting, requestId: nil)
                                    }
                                }
                            }
                        }
                    )
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.complete(
                                id: operationID,
                                detail: "BLAST results ready for \(sequences.count) unresolved sequence\(sequences.count == 1 ? "" : "s")"
                            )
                            controller.showBlastResults(result)
                            controller.onUnresolvedBlastCancelRequested = nil
                        }
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            OperationCenter.shared.fail(
                                id: operationID,
                                detail: message,
                                errorMessage: message
                            )
                            controller.showBlastFailure(message)
                            controller.onUnresolvedBlastCancelRequested = nil
                        }
                    }
                }
            }
            OperationCenter.shared.setCancelCallback(for: operationID) { task.cancel() }
        }

        annotationDrawerView?.isHidden = true
        fastqMetadataDrawerView?.isHidden = true

        let resultView = controller.view
        resultView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resultView)
        NSLayoutConstraint.activate([
            resultView.topAnchor.constraint(equalTo: view.topAnchor),
            resultView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            resultView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            resultView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        controller.configure(result: result)
        twelveSAmpliconResultViewController = controller

        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true

        return controller
    }

    func hideTwelveSAmpliconResultView() {
        guard let controller = twelveSAmpliconResultViewController else { return }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        twelveSAmpliconResultViewController = nil

        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = (geneTabBarView?.selectedGeneRegion == nil)
        annotationDrawerView?.isHidden = false
        fastqMetadataDrawerView?.isHidden = false
    }

    private nonisolated static func twelveSBlastSequences(fromFasta fastaURL: URL) throws -> [(id: String, sequence: String)] {
        let text = try String(contentsOf: fastaURL, encoding: .utf8)
        var records: [(id: String, sequence: String)] = []
        var currentID: String?
        var currentSequence = ""
        func flush() {
            guard let currentID else { return }
            let sequence = currentSequence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sequence.isEmpty else { return }
            records.append((id: currentID, sequence: sequence))
        }
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix(">") {
                flush()
                currentID = String(line.dropFirst().split(separator: " ").first ?? "")
                currentSequence = ""
            } else {
                currentSequence += line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        flush()
        return records
    }

    private nonisolated static func verifyTwelveSBlastPreparationProvenance(
        sidecarURL: URL,
        outputURL: URL
    ) throws {
        guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL),
              envelope.toolName == "lungfish-cli",
              envelope.workflowName == "lungfish fastq 12s-export-unresolved",
              envelope.exitStatus == 0,
              !envelope.argv.isEmpty else {
            throw LocalWorkflowExecutionError.invalidProvenance(sidecarURL.path)
        }
        let outputPath = outputURL.standardizedFileURL.path
        let outputPaths = Set(
            (envelope.outputs + envelope.steps.flatMap(\.outputs))
                .map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        )
        guard outputPaths.contains(outputPath) else {
            throw LocalWorkflowExecutionError.invalidProvenance(sidecarURL.path)
        }
    }
}
