// MainSplitViewController+CrossProjectCopy.swift - Dropped Lungfish items copied whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

extension MainSplitViewController {

    /// Splits dropped sources into Lungfish items (bundles and analysis result
    /// folders) that go through ``CrossProjectItemCopier`` and everything
    /// else, which keeps its existing import path.
    ///
    /// MHC reference databases stay on the dedicated installer path even
    /// though they are bundles.
    nonisolated static func partitionDroppedSources(_ urls: [URL]) -> (projectItems: [URL], other: [URL]) {
        var projectItems: [URL] = []
        var other: [URL] = []
        for url in urls {
            if !MHCAmpliconReferenceBundle.isBundleURL(url), CrossProjectItemCopier.isCopyableProjectItem(url) {
                projectItems.append(url)
            } else {
                other.append(url)
            }
        }
        return (projectItems, other)
    }

    /// Copies each dropped Lungfish item into the open project, one after the
    /// other, reporting each as an operation. When a single item was dropped
    /// it is selected and shown once the copy lands.
    func importProjectItemsFromDrop(
        urls: [URL],
        projectURL: URL,
        requestedFolder: URL?,
        requestID: String?,
        displayAfterImport: Bool,
        onFinished: (@MainActor () -> Void)? = nil
    ) {
        guard !urls.isEmpty else {
            onFinished?()
            return
        }
        let routeContext = operationRouteContext
        Task { @MainActor [weak self] in
            defer { onFinished?() }
            guard let self else { return }
            var outcome = SidebarDragDropOutcome(kind: .copy)
            var lastDestination: URL?

            for url in urls {
                let startResult = Self.beginCrossProjectCopyOperation(
                    itemURL: url,
                    projectURL: projectURL,
                    requestedFolder: requestedFolder,
                    routeContext: routeContext
                )
                guard case .started(let opID) = startResult else {
                    outcome.recordSkip(title: url.lastPathComponent, reason: .fileSystemError("Bundle is busy"))
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: "Bundle is busy")
                    continue
                }

                let result = await Self.copyDroppedProjectItem(
                    url, intoProject: projectURL, requestedFolder: requestedFolder, operationID: opID
                )

                switch result {
                case .success(let copied):
                    outcome.recordSuccess()
                    lastDestination = copied.destinationURL
                    Self.completeCrossProjectCopyRow(opID, landed: copied, projectURL: projectURL)
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: true, error: nil)
                case .failure(let error) where error is CancellationError:
                    // The runner acknowledged the cancel, so the row ends Cancelled. A cancel is no failure to alert about.
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: "Cancelled")
                case .failure(let error):
                    let message = error.localizedDescription
                    mainSplitLogger.error("importProjectItemsFromDrop: \(url.lastPathComponent, privacy: .public) failed: \(message, privacy: .public)")
                    _ = OperationCenter.shared.fail(id: opID, detail: message)
                    outcome.recordSkip(title: url.lastPathComponent, reason: .fileSystemError(message))
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: message)
                }
            }

            sidebarController.requestReloadFromFilesystem()
            if displayAfterImport, urls.count == 1, let lastDestination {
                displayImportedProjectFile(at: lastDestination)
            }
            if outcome.hasPartialFailure, let window = view.window {
                let alert = NSAlert()
                alert.messageText = outcome.alertTitle
                alert.informativeText = outcome.alertInformativeText(totalSelected: urls.count)
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// Registers the row for copying one dropped Lungfish item into the open
    /// project and returns the result. The row locks no bundle, as before,
    /// and the launch skips the item on a refusal.
    ///
    /// The row records the `lungfish-cli project copy-item` command the copy
    /// runs.
    @discardableResult
    static func beginCrossProjectCopyOperation(
        itemURL: URL,
        projectURL: URL,
        requestedFolder: URL?,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared
    ) -> OperationStartResult {
        let command = CrossProjectCopyRoute.command(itemURL: itemURL, projectURL: projectURL, requestedFolder: requestedFolder)
        return reporter.begin(
            title: "Copy \(itemURL.lastPathComponent)",
            detail: "Copying into \(projectURL.deletingPathExtension().lastPathComponent)...",
            operationType: .ingestion,
            cliCommand: command,
            routeContext: routeContext
        )
    }

    /// Copies one dropped item for the row `operationID`. The failure is
    /// `CancellationError` once the row's cancel is acknowledged.
    static func copyDroppedProjectItem(
        _ itemURL: URL,
        intoProject projectURL: URL,
        requestedFolder: URL?,
        operationID: UUID,
        launch: CrossProjectCopyRoute.Launch = CrossProjectCopyRoute.launchCommand
    ) async -> Result<CrossProjectCopyRoute.Landed, any Error> {
        do {
            return .success(try await CrossProjectCopyRoute.copy(
                itemURL: itemURL, projectURL: projectURL, requestedFolder: requestedFolder,
                operationID: operationID, launch: launch
            ))
        } catch {
            return .failure(error)
        }
    }

    /// Completes the row of a copy that landed, with a warning when the
    /// project lacks some of the item's sources. The command logged each of
    /// them on the row.
    static func completeCrossProjectCopyRow(
        _ operationID: UUID,
        landed: CrossProjectCopyRoute.Landed,
        projectURL: URL,
        reporter: any OperationReporting = OperationCenter.shared
    ) {
        let detail = "Copied to \(projectRelativeDescription(of: landed.destinationURL, in: projectURL))"
        guard let record = landed.record, record.hasMissingSources else {
            _ = reporter.complete(id: operationID, detail: detail, outputURLs: [landed.destinationURL])
            return
        }
        _ = reporter.completeWithWarning(
            id: operationID,
            detail: "\(detail). \(record.unresolvedLinks.count) source item(s) not in this project."
        )
    }

    nonisolated static func projectRelativeDescription(of url: URL, in projectURL: URL) -> String {
        if let relative = ProjectItemLinkRewriter.relative(
            path: url.standardizedFileURL.path,
            toAny: ProjectItemLinkRewriter.pathVariants(of: projectURL)
        ), !relative.isEmpty {
            return relative
        }
        return url.lastPathComponent
    }
}
