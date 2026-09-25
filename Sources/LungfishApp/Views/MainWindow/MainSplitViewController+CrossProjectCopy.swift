// MainSplitViewController+CrossProjectCopy.swift - Dropped Lungfish items copied whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
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
                let startResult = OperationCenter.shared.begin(
                    title: "Copy \(url.lastPathComponent)",
                    detail: "Copying into \(projectURL.deletingPathExtension().lastPathComponent)...",
                    operationType: .ingestion,
                    routeContext: routeContext
                )
                guard case .started(let opID) = startResult else {
                    outcome.recordSkip(title: url.lastPathComponent, reason: .fileSystemError("Bundle is busy"))
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: false, error: "Bundle is busy")
                    continue
                }

                let result: Result<CrossProjectItemCopier.Outcome, any Error> = await Task.detached(priority: .userInitiated) {
                    Result { try CrossProjectItemCopier.copy(itemAt: url, intoProject: projectURL, requestedFolder: requestedFolder) }
                }.value

                switch result {
                case .success(let copied):
                    outcome.recordSuccess()
                    lastDestination = copied.destinationURL
                    let landed = "Copied to \(Self.projectRelativeDescription(of: copied.destinationURL, in: projectURL))"
                    if copied.record.hasMissingSources {
                        for line in copied.record.missingSourceSummaryLines {
                            OperationCenter.shared.log(id: opID, level: .warning, message: line)
                        }
                        _ = OperationCenter.shared.completeWithWarning(
                            id: opID,
                            detail: "\(landed). \(copied.record.unresolvedLinks.count) source item(s) not in this project."
                        )
                    } else {
                        _ = OperationCenter.shared.complete(id: opID, detail: landed, outputURLs: [copied.destinationURL])
                    }
                    postSidebarFileDropCompleted(requestID: requestID, sourceURL: url, success: true, error: nil)
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
