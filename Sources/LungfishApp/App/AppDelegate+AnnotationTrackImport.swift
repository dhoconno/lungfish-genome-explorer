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
        let startResult = OperationCenter.shared.begin(
            title: "Annotation Import",
            detail: "Importing \(annotationURL.lastPathComponent)...",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: nil, // cli-parity-gap: annotation-attach-import-center. No command attaches a track.
            routeContext: routeContext
        )
        guard case .started(let opID) = startResult else {
            // The bundle is locked by another operation. The visible
            // "Bundle is busy" row is already inserted; do not import.
            return
        }

        do {
            let result = try await ReferenceBundleAnnotationImportService()
                .attachAnnotationTrack(
                    sourceURL: annotationURL,
                    bundleURL: bundleURL,
                    trackID: trackID,
                    trackName: trackName
                )
            guard OperationCenter.shared.complete(
                id: opID,
                detail: "Imported \(result.featureCount) annotations"
            ) else { return }
            let targetController = targetMainWindowController(routeContext: routeContext)
            refreshSidebarAndSelectImportedURL(bundleURL, in: targetController)
            if let viewerController = targetController?.mainSplitViewController?.viewerController,
               viewerController.currentBundleURL?.standardizedFileURL == bundleURL.standardizedFileURL {
                try viewerController.displayBundle(at: bundleURL)
            }
        } catch {
            guard OperationCenter.shared.fail(id: opID, detail: error.localizedDescription) else { return }
            showAlert(title: "Annotation Import Failed", message: error.localizedDescription)
        }
    }
}
