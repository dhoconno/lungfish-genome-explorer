// AppDelegate+ImportCenterFASTA.swift - The Import Center's reference sequence import from a URL, moved out of AppDelegate+ImportCenter.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow

/// The Import Center's reference sequence import from a URL lives here,
/// moved out of AppDelegate+ImportCenter.swift, which is at its size baseline.
extension AppDelegate {

    func importFASTAFromURL(
        _ url: URL,
        routeContext: OperationRouteContext? = nil,
        durableProvenanceInputFiles: [URL]? = nil,
        preferredBundleName: String? = nil,
        rehydrateSourceProvenance: Bool = false
    ) {
        guard let controller = targetMainWindowController(routeContext: routeContext) ?? activeMainWindowController(),
              let sidebarController = controller.mainSplitViewController?.sidebarController,
              let projectURL = routeContext?.projectURL ?? sidebarController.currentProjectURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing reference sequences.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope,
            workflowName: "Reference import",
            presentingWindow: controller.window
        ) else { return }

        guard ReferenceBundleImportService.isStandaloneReferenceSource(url) else {
            let classification = ReferenceBundleImportService.classify(url)
            let message: String
            switch classification {
            case .annotationTrack:
                message = "Annotation files should be imported into an existing reference bundle."
            case .variantTrack:
                message = "VCF/BCF files should be imported with the variant import workflow."
            case .alignmentTrack:
                message = "Alignment files should be imported into an existing reference bundle."
            case .unsupported:
                message = "This file type is not supported for standalone reference import."
            case .standaloneReferenceSequence:
                message = "Unexpected reference import classification."
            }
            showAlert(title: "Unsupported Reference Import", message: message)
            return
        }

        do {
            _ = try ReferenceSequenceFolder.ensureFolder(in: projectURL)
        } catch {
            showFailure(AppFailureReports.prepareReferenceSequencesFolder(error))
            return
        }

        // The context always names the project the bundle was written to. A
        // caller that knew only its window (Create Bundle on an assembly
        // result) used to pass the context on without a project, and the
        // completed bundle was then copied into another project's Downloads.
        let routeContext = OperationRouteContext(
            projectURL: projectURL,
            windowStateScopeID: routeContext?.windowStateScopeID ?? controller.projectSession.windowStateScope.id
        )
        // The import runs `import fasta` (2.11 A48 M3), which builds and publishes the bundle in
        // the Reference Sequences folder, records the durable inputs and merges the source's
        // record, so the app writes nothing after it exits.
        let provenanceInputFiles = durableProvenanceInputFiles ?? []
        let arguments = Self.referenceImportArguments(
            sourceURL: url,
            projectURL: projectURL,
            preferredBundleName: preferredBundleName,
            provenanceInputFiles: provenanceInputFiles,
            rehydrateSourceProvenance: rehydrateSourceProvenance
        )
        Self.beginReferenceImportOperation(
            sourceURL: url,
            projectURL: projectURL,
            preferredBundleName: preferredBundleName,
            provenanceInputFiles: provenanceInputFiles,
            rehydrateSourceProvenance: rehydrateSourceProvenance,
            routeContext: routeContext
        ) { opID in
            Task { @MainActor [weak self] in
                let outcome = await Self.runReferenceImport(arguments: arguments, operationID: opID, run: { arguments, id in
                    try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: id)
                })
                guard let error = outcome.error else { return }
                self?.showFailure(AppFailureReports.importReferenceSequence(error))
            }
        }
    }
}
