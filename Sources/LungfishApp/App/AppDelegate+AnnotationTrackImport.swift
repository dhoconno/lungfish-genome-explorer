// AppDelegate+AnnotationTrackImport.swift - The Import Center's annotation track import, moved out of AppDelegate+ImportCenter.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The Import Center's annotation track import lives here, so that
/// AppDelegate+ImportCenter.swift, which is at its size baseline, does not
/// hold it. `importAnnotationTracksFromURLs` checks the files and the
/// project and asks for the track's identity, and
/// `performSingleAnnotationTrackImport` registers the row and attaches one
/// file to the chosen reference bundle.
extension AppDelegate {
    /// Import a GTF/GFF/GFF3/BED annotation track from a known URL (called from Import Center).
    func importAnnotationTrackFromURL(_ url: URL) {
        importAnnotationTracksFromURLs([url])
    }

    /// Import GTF/GFF/GFF3/BED annotation tracks from known URLs (called from Import Center).
    func importAnnotationTracksFromURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let unsupported = urls.filter { ReferenceBundleImportService.classify($0) != .annotationTrack }
        guard unsupported.isEmpty else {
            showAlert(title: "Unsupported Annotation Import", message: "Select a GTF, GFF, GFF3, or BED file.")
            return
        }

        guard let originController = activeMainWindowController(),
              let originSplit = originController.mainSplitViewController,
              let projectURL = originSplit.sidebarController.currentProjectURL
                ?? workingDirectoryURL else {
            showAlert(title: "No Project Open", message: "Please open a project before importing annotation tracks.")
            return
        }
        guard canWriteProjectOutputs(
            projectURL: projectURL,
            windowStateScope: originController.projectSession.windowStateScope,
            workflowName: "Annotation import",
            presentingWindow: originController.window
        ) else { return }

        let preferredBundleURL = originSplit.viewerController.currentBundleURL
        ReferenceBundleAnnotationImportConfigurationPresenter.present(
            projectURL: projectURL,
            preferredBundleURL: preferredBundleURL,
            sourceURL: urls[0],
            presentingWindow: originController.window
        ) { [weak self] configuration in
            guard let self, let configuration else { return }
            if urls.count == 1 {
                Task { [weak self] in
                    await self?.performSingleAnnotationTrackImport(
                        annotationURL: urls[0],
                        configuration: configuration
                    )
                }
            } else {
                self.performAnnotationTrackImports(
                    annotationURLs: urls,
                    bundleURL: configuration.bundleURL
                )
            }
        }
    }

    private func performAnnotationTrackImports(annotationURLs: [URL], bundleURL: URL) {
        guard !annotationURLs.isEmpty else { return }

        Task { [weak self] in
            for annotationURL in annotationURLs {
                await self?.performSingleAnnotationTrackImport(annotationURL: annotationURL, bundleURL: bundleURL)
            }
        }
    }

    private func performSingleAnnotationTrackImport(
        annotationURL: URL,
        configuration: ReferenceBundleAnnotationImportConfiguration
    ) async {
        await performSingleAnnotationTrackImport(
            annotationURL: annotationURL,
            bundleURL: configuration.bundleURL,
            trackID: configuration.trackID,
            trackName: configuration.trackName
        )
    }

    private func performSingleAnnotationTrackImport(annotationURL: URL, bundleURL: URL) async {
        await performSingleAnnotationTrackImport(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            trackID: nil,
            trackName: nil
        )
    }

    private func performSingleAnnotationTrackImport(
        annotationURL: URL,
        bundleURL: URL,
        trackID: String?,
        trackName: String?
    ) async {
        let routeContext = currentOperationRouteContext()
        guard canWriteProjectOutputs(
            projectURL: ProjectTempDirectory.findProjectRoot(bundleURL),
            windowStateScope: routeContext?.windowStateScopeID.map(WindowStateScope.init(id:)),
            workflowName: "Annotation import"
        ) else { return }
        // A refused row is the visible "Bundle is busy" row, and nothing is imported.
        await Self.beginAnnotationTrackImportOperation(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            trackID: trackID,
            trackName: trackName,
            routeContext: routeContext
        ) { opID, arguments in
            do {
                // `sequence attach-track` writes the track and its records. Its complete message
                // is today's "Imported <n> annotations".
                let result = try await CLIBundleEditRunner.launch(arguments: arguments, operationID: opID)
                guard OperationCenter.shared.complete(
                    id: opID,
                    detail: result.message ?? "Imported annotations"
                ) else { return }
                let targetController = targetMainWindowController(routeContext: routeContext)
                refreshSidebarAndSelectImportedURL(bundleURL, in: targetController)
                if let viewerController = targetController?.mainSplitViewController?.viewerController,
                   viewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                    try viewerController.displayBundle(at: bundleURL)
                }
            } catch {
                guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
                showFailure(AppFailureReports.importAnnotationTrack(error))
            }
        }
    }

    /// Registers the row that attaches one annotation file to a reference
    /// bundle as a track, for the Import Center and for a file dropped on the
    /// sidebar, and, only when it starts, awaits `launch` with the operation
    /// ID and the `lungfish-cli` argv to run. The edit parses a file from
    /// outside the bundle, so it launches `sequence attach-track` (plan
    /// decision C3), and the row records that argv. The row locks
    /// `bundleURL`, the bundle the attach writes. On a refusal the caller
    /// shows its own outcome, and nothing is launched.
    @discardableResult
    static func beginAnnotationTrackImportOperation(
        annotationURL: URL,
        bundleURL: URL,
        trackID: String? = nil,
        trackName: String? = nil,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID, [String]) async -> Void
    ) async -> OperationStartResult {
        let arguments = ReferenceBundleAnnotationImportService.attachTrackArguments(
            sourceURL: annotationURL, bundleURL: bundleURL, trackID: trackID, trackName: trackName
        ) + ["--format", "json"]
        let result = reporter.begin(
            title: "Annotation Import",
            detail: "Importing \(annotationURL.lastPathComponent)...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "sequence attach-track", args: Array(arguments.dropFirst(2))
            ),
            routeContext: routeContext
        )
        if case .started(let operationID) = result {
            await launch(operationID, arguments)
        }
        return result
    }
}
