// ViewerViewController+ConsensusDestination.swift - Where Generate Consensus writes a bundle or a FASTA
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// Where Generate Consensus writes a file or a bundle (Phase 3.0 lane CONSENSUS-DEST, owner WF-9, with the ARCH
/// and UX rulings on WF-9). A consensus saved as a bundle in a project goes into the project's Reference
/// Sequences folder with no file dialog, beside the bundles that Extract Sequences makes, because the bundle is a
/// derived reference that the project should hold. A viewer with no project asks for a place. A FASTA is an
/// export to a place the person names, so it always asks, and its panel opens in the project when there is one.
/// This lives apart from ViewerViewController+MappingOperationBegin.swift, which is at its size baseline.
extension ViewerViewController {
    /// The project that holds the mapping or reference the consensus came from, nil when the viewer has none.
    func consensusProjectURL(for context: AlignmentActionContext) -> URL? {
        if case .projectDerivedRoot(let root) = context.outputCapability,
           let project = ProjectTempDirectory.findProjectRoot(root) {
            return project
        }
        return projectURLForDerivedReferenceBundle()
    }

    /// The row's route context, the project and this window, so a finished bundle shows in this window's sidebar.
    func consensusRouteContext(for context: AlignmentActionContext) -> OperationRouteContext? {
        consensusProjectURL(for: context).map { OperationRouteContext(projectURL: $0, windowStateScope: windowStateScope) }
    }

    /// The `--output` of a consensus saved as `destination`, a file or a bundle, or nil when nothing should run
    /// because the person cancelled the save panel or the project cannot be written to.
    ///
    /// A bundle in a project is a free name in the project's Reference Sequences folder, made unique as the other
    /// Save as Bundle routes do, with no panel. Every other file or bundle asks, and the panel opens in the
    /// project when there is one.
    func resolveConsensusFileOutput(
        _ destination: DialogDestination,
        fileName: String,
        context: AlignmentActionContext,
        window: NSWindow
    ) async -> String? {
        let project = consensusProjectURL(for: context)
        if destination == .bundle, let project {
            guard canWriteProjectOutputs(projectURL: project, workflowName: "Generate Consensus") else { return nil }
            do {
                let folder = try ReferenceSequenceFolder.ensureFolder(in: project)
                return Self.nextAvailableBundleURL(suggestedName: fileName, pathExtension: "lungfishref", in: folder).path
            } catch {
                presentExtractionFailureAlert(
                    title: "Generate Consensus Failed",
                    message: "Lungfish could not make the Reference Sequences folder in the project for the consensus bundle. "
                        + "\(error.localizedDescription) Check that the project folder can be written to, then try again."
                )
                return nil
            }
        }
        let ext = destination == .bundle ? "lungfishref" : "fasta"
        guard let chosen = await alignmentExtractionSavePanelPresenter.present(
            suggestedName: "\(fileName).\(ext)", on: window, startingIn: project
        ) else {
            return nil
        }
        return normalizedConsensusDestination(chosen, extension: ext).path
    }

    func normalizedConsensusDestination(_ url: URL, extension ext: String) -> URL {
        let normalized = url.standardizedFileURL
        guard normalized.pathExtension.lowercased() != ext else { return normalized }
        return normalized.pathExtension.isEmpty
            ? normalized.appendingPathExtension(ext)
            : normalized.deletingPathExtension().appendingPathExtension(ext)
    }
}
